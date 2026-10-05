#!/usr/bin/env bash
set -euo pipefail

rootfs="${1:?usage: install-layers.sh <rootfs> <arch>}"
arch="${2:?usage: install-layers.sh <rootfs> <arch>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/.." && pwd)"

for layer in kernel tuning runtime board; do
  dir="$os_dir/layers/$layer"
  [ -d "$dir" ] || continue
  printf '[layers] applying %s\n' "$layer" >&2
  if [ -x "$dir/apply.sh" ]; then
    "$dir/apply.sh" "$rootfs" "$arch"
  fi
done
