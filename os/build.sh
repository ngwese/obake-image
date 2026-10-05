#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/.." && pwd)"

arch="${ARCH:-amd64}"
suite="${SUITE:-trixie}"
slot="${SLOT:-a}"
version="${VERSION:-0.0.0}"
mirror="${MIRROR:-http://deb.debian.org/debian}"
work="${WORK:-$project_root/.build/os/$arch-$slot}"
out="${OUT:-$project_root/dist/os/$arch}"

log() { printf '[build] %s\n' "$*" >&2; }
die() { printf '[build] error: %s\n' "$*" >&2; exit 1; }

layout_field() {
  python3 - "$here/partition-layout.json" "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for part in data["partitions"]:
    if part["role"] == sys.argv[2]:
        print(part[sys.argv[3]])
        break
else:
    raise SystemExit(f"unknown role: {sys.argv[2]}")
PY
}

command -v mmdebstrap >/dev/null || die "mmdebstrap not found; run in verification/build-env"
command -v ukify >/dev/null || die "ukify not found; Debian trixie systemd provides it"
command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 not found"

kernel_package() {
  case "$arch" in
    amd64) printf 'linux-image-amd64' ;;
    arm64) printf 'linux-image-arm64' ;;
    *) die "unsupported arch: $arch" ;;
  esac
}

rootfs="$work/rootfs"
root_label="$(layout_field "root_$slot" label)"

build_rootfs() {
  log "building $arch/$suite base rootfs"
  rm -rf "$work"
  mkdir -p "$work"
  mmdebstrap \
    --architectures="$arch" \
    --variant=minbase \
    --include="systemd,systemd-boot-efi,initramfs-tools,$(kernel_package),ca-certificates" \
    "$suite" "$rootfs" "$mirror"
  log "applying obake layers"
  "$here/scripts/install-layers.sh" "$rootfs" "$arch"
}

build_uki() {
  log "building UKI for slot $slot"
  local kver
  kver="$(find "$rootfs/boot" -maxdepth 1 -name 'vmlinuz-*' | sed 's#.*/vmlinuz-##' | sort -V | tail -1)"
  [ -n "$kver" ] || die "no kernel found in rootfs"
  mkdir -p "$out"
  ukify build \
    --linux="$rootfs/boot/vmlinuz-$kver" \
    --initrd="$rootfs/boot/initrd.img-$kver" \
    --cmdline="root=LABEL=$root_label ro" \
    --os-release="@$rootfs/etc/os-release" \
    --output="$out/obake-$slot.efi"
}

make_image() {
  log "packaging rootfs image for slot $slot"
  mkdir -p "$out"
  local size
  size="$(du -sm "$rootfs" | cut -f1)"
  size=$(( (size + 255) / 256 * 256 ))
  dd if=/dev/zero of="$out/root-$slot.img" bs=1M count="$size" status=none
  mkfs.ext4 -q -L "$root_label" -d "$rootfs" "$out/root-$slot.img"
}

sign() {
  log "signing artifacts"
  "$here/scripts/sign.sh" "$out"
}

build_rootfs
build_uki
make_image
sign
log "done: $out (version $version)"
