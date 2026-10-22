#!/usr/bin/env bash
#
# Build an obake host image from a pinned Buildroot release.
#
#   build.sh <board> [make-args...]
#
# e.g. build.sh generic-aarch64
#
# <board> is one of generic-aarch64, generic-x86_64, qdl, or rk35xx. Every
# board is built from the same shared base (configs/obake_base.config) combined
# with the board fragment (configs/obake-<board>.config), so the base userland,
# kernel, and runtime are identical on every board and a board only adds its
# own arch, kernel config, and overlay. The target architecture follows from
# the board fragment (BR2_x86_64 / BR2_aarch64); there is no arch argument.
#
# OBAKE_PROFILE selects profiles/<board>/{default,virtual}.conf (defaulting to
# default). A profile supplies installer build defaults; an explicit environment
# setting wins over the profile.
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
	printf 'usage: %s <board> [make-args...]\n' "$0" >&2
	printf 'boards: generic-aarch64 generic-x86_64 qdl rk35xx\n' >&2
	exit 2
fi
board="$1"
shift

board_config="$here/configs/obake-$board.config"
if [ ! -f "$board_config" ]; then
	printf '[build] error: unknown board %s (%s)\n' "$board" "$board_config" >&2
	exit 2
fi
base_config="$here/configs/obake_base.config"

# Apply the board profile, keeping any installer knobs already set in the
# environment.
profile="${OBAKE_PROFILE:-default}"
profile_file="$here/profiles/$board/$profile.conf"
if [ ! -f "$profile_file" ]; then
	printf '[build] error: unknown profile %s for board %s\n' "$profile" "$board" >&2
	printf '[build] supported profiles:' >&2
	for f in "$here/profiles/$board"/*.conf; do
		[ -f "$f" ] || continue
		printf ' %s' "$(basename "$f" .conf)" >&2
	done
	printf '\n' >&2
	exit 2
fi
while IFS= read -r line || [ -n "$line" ]; do
	# Skip blanks and comments.
	case "$line" in
	'' | \#*) continue ;;
	esac
	key="${line%%=*}"
	val="${line#*=}"
	case "$key" in
	MAKE_INSTALLER | CONSOLE | INSTALLER_TARGET_DISK) ;;
	*) continue ;;
	esac
	# ${!key+x} is set when the variable is already in the environment.
	if [ -z "${!key+x}" ]; then
		export "$key=$val"
	fi
done <"$profile_file"
printf '[build] profile %s: MAKE_INSTALLER=%s CONSOLE=%s INSTALLER_TARGET_DISK=%s\n' \
	"$profile" "${MAKE_INSTALLER:-}" "${CONSOLE:-}" \
	"${INSTALLER_TARGET_DISK:-}" >&2

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

work="${OBAKE_WORK:-$here/../../_build/buildroot}"
if [ -n "${DL_DIR:-}" ]; then
	dl="$DL_DIR"
elif [ -d "$vendor/dl" ]; then
	dl="$vendor/dl"
else
	dl="$work/dl"
fi
src="$work/buildroot-$br_release"
out="${OBAKE_OUT:-$work/output/$board}"

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

# Compose the shared base with the board fragment into the defconfig Buildroot
# configures from. Board lines come last so they can override the base.
mkdir -p "$out"
merged="$out/defconfig"
cat "$base_config" "$board_config" >"$merged"

# OBAKE_BOARD lets the post-build and post-image hooks emit board-specific
# artifacts (console, bootloader) without re-deriving the board from the config.
export OBAKE_BOARD="$board"

# Kernel local version (-<rev>-<board>) from the image git history of this
# board's kernel configuration. Refresh on every invocation; if it changed
# since the last build, drop linux stamps so the package rebuilds with the
# new release string. A non-zero helper status (shallow checkout) fails the
# build.
rev_helper="$here/../scripts/kernel-config-rev.sh"
lv="$("$rev_helper" "$board")"
lv_stamp="$out/obake-kernel-localversion"
prev_lv=""
[ -f "$lv_stamp" ] && prev_lv="$(tr -d '[:space:]' <"$lv_stamp")"
printf '%s\n' "$lv" >"$lv_stamp"
export OBAKE_KERNEL_LOCALVERSION="$lv"
printf '[build] kernel localversion=%s\n' "$lv" >&2
if [ -n "$prev_lv" ] && [ "$prev_lv" != "$lv" ]; then
	printf '[build] localversion changed (%s -> %s); forcing linux rebuild\n' \
		"$prev_lv" "$lv" >&2
	for d in "$out"/build/linux-*/; do
		[ -d "$d" ] || continue
		rm -f "${d}localversion-obake" \
			"${d}.stamp_built" "${d}.stamp_target_installed" \
			"${d}.stamp_images_installed" "${d}.stamp_staging_installed"
	done
fi

make -C "$src" O="$out" BR2_EXTERNAL="$here" DL_DIR="$dl" DEFCONFIG="$merged" defconfig
make -C "$src" O="$out" BR2_EXTERNAL="$here" DL_DIR="$dl" "$@"
