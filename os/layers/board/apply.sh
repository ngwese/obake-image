#!/usr/bin/env bash
set -euo pipefail

# Board layer: hardware-specific tuning for a target board, layered over the one
# shared base. Adding a board adds a directory under os/boards/ and a package
# entry in os/manifest.json; it never forks the base or higher layers.

rootfs="${1:?usage: board/apply.sh <rootfs> <arch> [board]}"
arch="${2:?}"
board="${3:-generic}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/../.." && pwd)"
board_dir="$os_dir/boards/$board"

if [ ! -d "$board_dir" ]; then
  printf '[board] error: unknown board %s (expected %s)\n' "$board" "$board_dir" >&2
  exit 1
fi

if [ -d "$board_dir/files" ]; then
  cp -a "$board_dir/files/." "$rootfs/"
fi

install -d "$rootfs/etc/obake"
printf 'board=%s\narch=%s\n' "$board" "$arch" >"$rootfs/etc/obake/board"
