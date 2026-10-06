#!/usr/bin/env bash
set -euo pipefail

# Apply the obake layers to an unpacked rootfs. Packages for each layer are
# resolved from os/manifest.json by build.sh and installed by mmdebstrap; this
# script only lays down the file overlays and per-layer metadata, so it never
# needs to chroot into a foreign architecture.

rootfs="${1:?usage: install-layers.sh <rootfs> <arch> [board]}"
arch="${2:?usage: install-layers.sh <rootfs> <arch> [board]}"
board="${3:-generic}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/.." && pwd)"

for layer in kernel tuning runtime board; do
  dir="$os_dir/layers/$layer"
  [ -d "$dir" ] || continue
  if [ -x "$dir/apply.sh" ]; then
    printf '[layers] applying %s\n' "$layer" >&2
    "$dir/apply.sh" "$rootfs" "$arch" "$board"
  fi
done
