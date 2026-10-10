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
*BR2_aarch64=y*) arch=aarch64; kern=Image; efiarch=aa64; serial_cons=ttyAMA0; mkarch=arm64 ;;
*BR2_x86_64=y*) arch=x86_64; kern=bzImage; efiarch=x64; serial_cons=ttyS0; mkarch=amd64 ;;
*) log "error: unsupported architecture"; exit 1 ;;
esac

# The board selects the serial TTY and, for Rockchip, the raw bootloader region.
board="${OBAKE_BOARD:-}"
if [ -z "$board" ]; then
	if grep -q '^BR2_TARGET_UBOOT_NEEDS_ROCKCHIP_RKBIN=y' "$BR2_CONFIG"; then
		board=rk35xx
	else
		board="generic-$arch"
	fi
fi
[ "$board" = "rk35xx" ] && serial_cons=ttyS2
# shellcheck source=console-env.sh
. "$here/console-env.sh"
log "board=$board arch=$arch CONSOLE=$console_mode cmdline=$cmdline_console"

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
	for l in ld-linux-aarch64.so.1 ld-linux-x86-64.so.2 ld-linux.so.2 libc.so.6 \
		libm.so.6 libresolv.so.2 libgcc_s.so.1 libblkid.so.1 libuuid.so.1; do
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
	cmdline="root=PARTLABEL=$root_label $mode rootwait $cmdline_console loglevel=7 efi=runtime"
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
	# One bootable disk; both root slots and their UKIs are on it, so a single
	# image covers the active and inactive slots.
	slot="${DISK_SLOT:-a}"
	raw_bootloader=""
	disk_align="${DISK_ALIGN_MIB:-1}"
	if [ "$board" = "rk35xx" ]; then
		raw_bootloader="$binaries/u-boot-rockchip.bin"
		[ -f "$raw_bootloader" ] ||
			{ log "error: rk35xx bootloader u-boot-rockchip.bin not found"; exit 1; }
		# The Rockchip boot chain (DDR TPL + TF-A BL31 + U-Boot) lives in a raw
		# region before the first partition, so reserve the first 16 MiB.
		disk_align="${DISK_ALIGN_MIB:-16}"
	fi
	log "assembling disk-$slot.img"
	WORK="$binaries/.disk-work" USER_SIZE_MIB="${USER_SIZE_MIB:-2048}" \
		DISK_ALIGN_MIB="$disk_align" RAW_BOOTLOADER="$raw_bootloader" \
		bash "$scripts/make-disk.sh" "$slot" "$mkarch" "$binaries"
fi

if [ "${MAKE_INSTALLER:-0}" = "1" ]; then
	bash "$here/make-installer.sh" "$binaries"
fi

# Signed update bundles when MAKE_BUNDLE=1 and signing material is set.
# Signing keys alone do not request bundles (the installer product sets them
# for the image keyring). Each bundle carries one slot's rootfs and UKI.
# Default is both slots; set BUNDLE_SLOT=a|b to emit only one.
if [ "${MAKE_BUNDLE:-0}" = "1" ] &&
	[ -n "${RAUC_SIGNING_CERT:-}" ] && [ -n "${RAUC_SIGNING_KEY:-}" ]; then
	case "${BUNDLE_SLOT:-}" in
	a | b) bundle_slots="$BUNDLE_SLOT" ;;
	'') bundle_slots="a b" ;;
	*)
		printf '[post-image] error: BUNDLE_SLOT must be a, b, or empty (got %s)\n' \
			"$BUNDLE_SLOT" >&2
		exit 1
		;;
	esac
	# Drop prior-version bundles left in the persistent images tree so staging
	# does not publish stale obake-<old>-*.raucb alongside the current ones.
	for stale in "$binaries"/obake-*.raucb; do
		[ -f "$stale" ] || continue
		base="$(basename "$stale")"
		case "$base" in
		obake-"$version"-*.raucb) ;;
		*)
			log "removing stale bundle $base"
			rm -f "$stale"
			;;
		esac
	done
	for bundle_slot in $bundle_slots; do
		log "building signed update bundle for slot $bundle_slot"
		rm -f "$binaries/obake-$version-$bundle_slot.raucb"
		RAUC_SIGNING_CERT="$RAUC_SIGNING_CERT" RAUC_SIGNING_KEY="$RAUC_SIGNING_KEY" \
			bash "$scripts/make-bundle.sh" "$bundle_slot" "$version" \
			"$binaries/root-$bundle_slot.img" \
			"$binaries/obake-$bundle_slot.efi" "$binaries"
	done
fi

# Record the pinned inputs (Buildroot, kernel, runtime, EFI stub) alongside the
# artifacts, so a build's exact inputs are reproducible from the output alone.
bash "$scripts/pinned-inputs.sh" "$binaries" "$board" "$mkarch" "$TARGET_DIR"

log "writing version, checksums, manifest and signatures"
VERSION="$version" ARCH="$mkarch" SLOT=a \
	OBKA_SIGNING_KEY="${OBKA_SIGNING_KEY:-}" \
	bash "$scripts/sign.sh" "$binaries"
log "done: $arch version $version"
