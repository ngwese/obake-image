#!/usr/bin/env bash
#
# Image-tree git provenance shared by artifact directories and kernel
# LOCALVERSION injection.
#
# Usage:
#   image-git-rev.sh localversion   # -g<shortsha>[-dirty] or -gnogit
#   image-git-rev.sh sha            # <shortsha> or nogit
#   image-git-rev.sh dirty          # -dirty or empty
#
# Git is resolved from the image/ directory (parent of os/), matching
# image/build/build.sh artifact naming.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_root="$(cd "$here/../.." && pwd)"

mode="${1:-localversion}"
sha="nogit"
dirty=""
if got="$(git -C "$image_root" rev-parse --short HEAD 2>/dev/null)"; then
	sha="$got"
	if [ -n "$(git -C "$image_root" status --porcelain 2>/dev/null)" ]; then
		dirty="-dirty"
	fi
fi

case "$mode" in
localversion)
	printf -- '-g%s%s\n' "$sha" "$dirty"
	;;
sha)
	printf '%s\n' "$sha"
	;;
dirty)
	printf '%s\n' "$dirty"
	;;
*)
	printf 'usage: %s localversion|sha|dirty\n' "$0" >&2
	exit 2
	;;
esac
