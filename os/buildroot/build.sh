#!/usr/bin/env bash
#
# Build an obake host image from a pinned Buildroot release.
#
#   build.sh <defconfig> [make-args...]
#
# e.g. build.sh obake_aarch64_defconfig
#
# The Buildroot release and the realtime kernel source, with their SHA-256
# hashes, are read from pins.json and verified before the build starts, so an
# unchanged pins.json always selects the same base. The pinned inputs are
# vendored under vendor/ with git-lfs; when present they are used directly, so
# a release builds without network access. Run this inside a Linux container or
# on a Linux host; Buildroot cross-compiles and never executes target binaries,
# so any host architecture can build any target.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$here/pins.json"
vendor="$here/vendor"

if [ $# -lt 1 ]; then
	printf 'usage: %s <defconfig> [make-args...]\n' "$0" >&2
	exit 2
fi
defconfig="$1"
shift

pin() { # pin <jq-ish-path>
	python3 - "$pins" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
node = data
for key in sys.argv[2].split("."):
    node = node[key]
print(node)
PY
}

br_release="$(pin buildroot.release)"
br_url="$(pin buildroot.url)"
br_sha="$(pin buildroot.sha256)"
kver="$(pin kernel.version)"
kurl="$(pin kernel.url)"
ksha="$(pin kernel.sha256)"

work="${OBAKE_WORK:-$here/../../.build/buildroot}"
if [ -n "${DL_DIR:-}" ]; then
	dl="$DL_DIR"
elif [ -d "$vendor/dl" ]; then
	dl="$vendor/dl"
else
	dl="$work/dl"
fi
src="$work/buildroot-$br_release"
out="${OBAKE_OUT:-$work/output/$defconfig}"

verify() { # verify <file> <sha256>
	printf '%s  %s\n' "$2" "$1" | sha256sum -c - >/dev/null 2>&1
}

fetch() { # fetch <url> <dst> <sha256>
	local url="$1" dst="$2" sha="$3"
	if [ -f "$dst" ] && verify "$dst" "$sha"; then
		return 0
	fi
	printf '[build] fetching %s\n' "$url" >&2
	curl -fL --retry 3 --create-dirs -o "$dst.tmp" "$url"
	printf '%s  %s\n' "$sha" "$dst.tmp" | sha256sum -c - >&2
	mv "$dst.tmp" "$dst"
}

mkdir -p "$work" "$dl"

# Prefer the vendored Buildroot release; otherwise download and verify it.
br_tarball="$work/buildroot-$br_release.tar.gz"
if [ -f "$vendor/buildroot-$br_release.tar.gz" ]; then
	verify "$vendor/buildroot-$br_release.tar.gz" "$br_sha" ||
		{ printf '[build] error: vendored Buildroot tarball hash mismatch\n' >&2; exit 1; }
	br_tarball="$vendor/buildroot-$br_release.tar.gz"
else
	fetch "$br_url" "$br_tarball" "$br_sha"
fi

if [ ! -d "$src" ]; then
	tar -C "$work" -xzf "$br_tarball"
fi

# Seed the kernel tarball into Buildroot's download cache after verifying it.
fetch "$kurl" "$dl/linux-$kver.tar.xz" "$ksha"

make -C "$src" O="$out" BR2_EXTERNAL="$here" DL_DIR="$dl" "$defconfig"
make -C "$src" O="$out" BR2_EXTERNAL="$here" DL_DIR="$dl" "$@"
