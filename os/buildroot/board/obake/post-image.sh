#!/usr/bin/env bash
#
# obake Buildroot post-image hook.
#
# Runs after the root filesystem images are produced. It emits the per-slot
# unified kernel images, per-slot root images and archives, bootable disk
# images, and the version/checksum/manifest/signature set, reusing the shared
# partition layout and signing scripts.
set -euo pipefail

binaries="${1:?usage: post-image.sh <binaries-dir>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extroot="$(cd "$here/../.." && pwd)"
os_dir="$(cd "$extroot/.." && pwd)"
scripts="$os_dir/scripts"
layout="$os_dir/partition-layout.json"

log() { printf '[post-image] %s\n' "$*" >&2; }

version="${OBAKE_IMAGE_VERSION:-$(cat "$extroot/VERSION" 2>/dev/null || echo 0.0.0)}"

case "$(grep -E '^BR2_(aarch64|x86_64)=y' "$BR2_CONFIG")" in
*BR2_aarch64=y*) arch=aarch64; kern=Image; efiarch=aa64; cons=ttyAMA0; mkarch=arm64 ;;
*BR2_x86_64=y*) arch=x86_64; kern=bzImage; efiarch=x64; cons=ttyS0; mkarch=amd64 ;;
*) log "error: unsupported architecture"; exit 1 ;;
esac

stub="$TARGET_DIR/usr/lib/systemd/boot/efi/linux$efiarch.efi.stub"
if [ ! -f "$stub" ]; then
	# x86_64 builds the stub in-tree (BR2_PACKAGE_SYSTEMD_BOOT); aarch64 uses
	# the stub vendored under vendor/efi-stub/ (pinned in pins.json).
	stub="$extroot/vendor/efi-stub/linux$efiarch.efi.stub"
fi
[ -f "$stub" ] || { log "error: EFI stub not found for $arch"; exit 1; }
[ -f "$binaries/$kern" ] || { log "error: kernel not found: $binaries/$kern"; exit 1; }

ukify="$(command -v ukify || true)"
[ -n "$ukify" ] || ukify="$HOST_DIR/bin/ukify"
[ -x "$ukify" ] || { log "error: ukify not found (need host-systemd)"; exit 1; }

# Assemble the initramfs the UKIs bundle: busybox + libc + the obake init that
# mounts the root slot and overlays /etc from persist.
initramfs="$binaries/initramfs.gz"
assemble_initramfs() {
	d="$binaries/.initramfs"
	rm -rf "$d"
	mkdir -p "$d/bin" "$d/sbin" "$d/usr/bin" "$d/usr/lib" "$d/proc" "$d/sys" "$d/dev" "$d/run"
	ln -sf usr/lib "$d/lib"
	ln -sf lib "$d/lib64"
	ln -sf lib "$d/usr/lib64"
	install -m 0755 "$TARGET_DIR/bin/busybox" "$d/bin/busybox"
	for a in sh mount umount switch_root mkdir cat sleep echo head modprobe find; do
		ln -sf busybox "$d/bin/$a"
	done
	if [ -x "$TARGET_DIR/usr/bin/blkid" ]; then
		install -m 0755 "$TARGET_DIR/usr/bin/blkid" "$d/usr/bin/blkid"
		ln -sf ../usr/bin/blkid "$d/bin/blkid"
	fi
	for l in ld-linux-aarch64.so.1 ld-linux.so.2 libc.so.6 libm.so.6 \
		libresolv.so.2 libgcc_s.so.1 libblkid.so.1 libuuid.so.1; do
		[ -e "$TARGET_DIR/usr/lib/$l" ] && cp -L "$TARGET_DIR/usr/lib/$l" "$d/usr/lib/"
	done
	install -m 0755 "$here/initramfs/init" "$d/init"
	( cd "$d" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 ) >"$initramfs"
	log "assembled initramfs ($(du -h "$initramfs" | cut -f1))"
}
assemble_initramfs

label_for() {
	python3 - "$layout" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for part in data["partitions"]:
    if part["role"] == sys.argv[2]:
        print(part["label"])
        break
PY
}

for slot in a b; do
	root_label="$(label_for "root_$slot")"
	mode=ro
	[ "${BREAK:-}" = "ro" ] && mode=rw
	cmdline="root=PARTLABEL=$root_label $mode rootwait console=$cons loglevel=7 efi=runtime"
	log "building UKI for slot $slot ($cmdline)"
	"$ukify" build \
		--linux="$binaries/$kern" \
		--initrd="$initramfs" \
		--cmdline="$cmdline" \
		--os-release="@$TARGET_DIR/etc/os-release" \
		--stub="$stub" \
		--output="$binaries/obake-$slot.efi"
	cp -f "$binaries/rootfs.ext4" "$binaries/root-$slot.img"
	cp -f "$binaries/rootfs.tar" "$binaries/root-$slot.tar"
done

if [ "${MAKE_DISK:-1}" = "1" ]; then
	for slot in a b; do
		log "assembling disk-$slot.img"
		WORK="$binaries/.disk-work" USER_SIZE_MIB="${USER_SIZE_MIB:-2048}" \
			"$scripts/make-disk.sh" "$slot" "$mkarch" "$binaries"
	done
fi

if [ "${MAKE_INSTALLER:-0}" = "1" ]; then
	"$here/make-installer.sh" "$binaries"
fi

# A signed update bundle for the inactive slot, when signing material is set.
if [ -n "${RAUC_SIGNING_CERT:-}" ] && [ -n "${RAUC_SIGNING_KEY:-}" ]; then
	log "building signed update bundle"
	RAUC_SIGNING_CERT="$RAUC_SIGNING_CERT" RAUC_SIGNING_KEY="$RAUC_SIGNING_KEY" \
		"$scripts/make-bundle.sh" b "$version" \
		"$binaries/root-b.img" "$binaries/obake-b.efi" "$binaries"
fi

log "writing version, checksums, manifest and signatures"
VERSION="$version" ARCH="$mkarch" SLOT=a \
	OBKA_SIGNING_KEY="${OBKA_SIGNING_KEY:-}" \
	"$scripts/sign.sh" "$binaries"

log "done: $arch version $version"
