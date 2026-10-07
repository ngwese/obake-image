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
	cmdline="root=PARTLABEL=$root_label ro rootwait console=$cons loglevel=7 efi=runtime"
	log "building UKI for slot $slot ($cmdline)"
	"$ukify" build \
		--linux="$binaries/$kern" \
		--cmdline="$cmdline" \
		--os-release="@$TARGET_DIR/etc/os-release" \
		--stub="$stub" \
		--output="$binaries/obake-$slot.efi"
	cp -f "$binaries/rootfs.ext4" "$binaries/root-$slot.img"
	cp -f "$binaries/rootfs.tar" "$binaries/root-$slot.tar"
done

for slot in a b; do
	log "assembling disk-$slot.img"
	WORK="$binaries/.disk-work" USER_SIZE_MIB="${USER_SIZE_MIB:-2048}" \
		"$scripts/make-disk.sh" "$slot" "$mkarch" "$binaries"
done

log "writing version, checksums, manifest and signatures"
VERSION="$version" ARCH="$mkarch" SLOT=a \
	OBKA_SIGNING_KEY="${OBKA_SIGNING_KEY:-}" \
	"$scripts/sign.sh" "$binaries"

log "done: $arch version $version"
