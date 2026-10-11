#!/usr/bin/env bash
#
# Kernel local version from the image git history of a board's kernel
# configuration.
#
# Usage:
#   kernel-config-rev.sh <board>    # -<board>-<rev>
#
# <rev> is the 1-based index of the current kernel-config hash in the ordered
# set of distinct hashes seen in git history, oldest first. The same hash
# reuses its rev. A dirty tree with a new hash uses the next rev and is not
# written back. A shallow checkout fails. When git metadata cannot be read
# the script prints -<board>-0.
#
# OBAKE_IMAGE_ROOT overrides the image repository (parent of os/). The build
# leaves it unset.
set -euo pipefail

if [ "$#" -ne 1 ]; then
	printf 'usage: %s <board>\n' "$0" >&2
	exit 2
fi
board="$1"
case "$board" in
'' | *[!A-Za-z0-9._-]*)
	printf 'kernel-config-rev: invalid board %s\n' "$board" >&2
	exit 2
	;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${OBAKE_IMAGE_ROOT:-}" ]; then
	image_root="$(cd "$OBAKE_IMAGE_ROOT" && pwd)"
else
	image_root="$(cd "$here/../.." && pwd)"
fi

# Build containers often run as a different uid than the bind-mounted tree.
git config --global --add safe.directory "$image_root" >/dev/null 2>&1 || true

if ! git -C "$image_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
	! git -C "$image_root" rev-parse --verify HEAD >/dev/null 2>&1; then
	printf -- '-%s-0\n' "$board"
	exit 0
fi
if [ "$(git -C "$image_root" rev-parse --is-shallow-repository 2>/dev/null || true)" = true ]; then
	printf 'kernel-config-rev: shallow image git checkout\n' >&2
	exit 1
fi

paths=(
	"os/buildroot/board/obake/linux-realtime.fragment"
	"os/buildroot/board/obake/linux-obake.fragment"
	"os/buildroot/board/obake/${board}/linux.config"
	"os/buildroot/configs/obake_base.config"
	"os/buildroot/configs/obake-${board}.config"
)

# Drop blanks, comments, CONFIG_LOCALVERSION, and (for Buildroot defconfigs)
# the kernel source-pin lines. Defconfigs contribute only kernel-selection lines.
normalize() {
	local kind="$1"
	awk -v kind="$kind" '
		{
			sub(/^[ \t]+/, "")
			if ($0 == "" || $0 ~ /^#/) next
			if ($0 ~ /CONFIG_LOCALVERSION/) next
			if (kind == "defconfig") {
				if ($0 ~ /^BR2_LINUX_KERNEL_CUSTOM_VERSION=/) next
				if ($0 ~ /^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=/) next
				if ($0 ~ /^BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=/) next_ok = 1
				else if ($0 ~ /^BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE=/) next_ok = 1
				else if ($0 ~ /^BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=/) next_ok = 1
				else if ($0 ~ /^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=/) next_ok = 1
				else if ($0 ~ /^BR2_LINUX_KERNEL_DTS/) next_ok = 1
				else if ($0 ~ /^BR2_LINUX_KERNEL_INTREE_DTS/) next_ok = 1
				else next_ok = 0
				if (!next_ok) next
			}
			print
		}
	'
}

kind_of() {
	case "$1" in
	os/buildroot/configs/obake_base.config | os/buildroot/configs/obake-*.config)
		printf 'defconfig\n'
		;;
	*)
		printf 'config\n'
		;;
	esac
}

# Hash the kernel-config inputs. With a commit, read that tree; otherwise the
# working tree. Missing files are omitted.
hash_inputs() {
	local commit="${1:-}"
	local path kind
	{
		for path in "${paths[@]}"; do
			kind="$(kind_of "$path")"
			if [ -n "$commit" ]; then
				git -C "$image_root" cat-file -e "${commit}:${path}" 2>/dev/null || continue
				printf 'FILE %s\n' "$path"
				git -C "$image_root" show "${commit}:${path}" | normalize "$kind"
				printf '\n'
			else
				[ -f "$image_root/$path" ] || continue
				printf 'FILE %s\n' "$path"
				normalize "$kind" <"$image_root/$path"
				printf '\n'
			fi
		done
	} | sha256sum | awk '{print $1}'
}

hashes=()
seen_hash() {
	local h="$1" existing
	for existing in "${hashes[@]+"${hashes[@]}"}"; do
		[ "$existing" = "$h" ] && return 0
	done
	return 1
}

while IFS= read -r commit; do
	[ -n "$commit" ] || continue
	h="$(hash_inputs "$commit")"
	if ! seen_hash "$h"; then
		hashes+=("$h")
	fi
done < <(git -C "$image_root" log --reverse --format=%H -- "${paths[@]}")

current="$(hash_inputs)"
rev=""
i=1
for h in "${hashes[@]+"${hashes[@]}"}"; do
	if [ "$h" = "$current" ]; then
		rev="$i"
		break
	fi
	i=$((i + 1))
done
if [ -z "$rev" ]; then
	rev=$((${#hashes[@]} + 1))
fi
printf -- '-%s-%s\n' "$board" "$rev"
