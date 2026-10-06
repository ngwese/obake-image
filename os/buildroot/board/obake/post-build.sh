#!/usr/bin/env bash
#
# obake Buildroot post-build hook.
#
# Runs after every package is built and before the root filesystem is
# assembled. It records the built kernel version and the image version under
# /etc/obake and refuses to produce an image whose kernel is not configured for
# realtime (CONFIG_PREEMPT_RT).
set -euo pipefail

target_dir="${1:?usage: post-build.sh <target-dir>}"
extroot="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

image_version="${OBAKE_IMAGE_VERSION:-$(cat "${extroot}/VERSION" 2>/dev/null || echo 0.0.0)}"

# Architecture, read from the Buildroot configuration exported by Buildroot.
arch="unknown"
if grep -q '^BR2_aarch64=y' "${BR2_CONFIG:-/dev/null}"; then
	arch="aarch64"
elif grep -q '^BR2_x86_64=y' "${BR2_CONFIG:-/dev/null}"; then
	arch="x86_64"
fi

# The version of the kernel actually built, taken from the modules tree.
kver=""
for d in "${target_dir}"/lib/modules/*/; do
	[ -d "$d" ] || continue
	kver="$(basename "$d")"
done
[ -n "$kver" ] || {
	printf '[post-build] error: no kernel modules found in %s/lib/modules\n' \
		"$target_dir" >&2
	exit 1
}

# Refuse an image whose kernel is not realtime.
kconfig=""
for c in "${BASE_DIR:-}"/build/linux-*/.config; do
	[ -f "$c" ] || continue
	kconfig="$c"
done
if [ -z "$kconfig" ] || ! grep -q '^CONFIG_PREEMPT_RT=y' "$kconfig"; then
	printf '[post-build] error: realtime kernel config (CONFIG_PREEMPT_RT) missing\n' >&2
	exit 1
fi

mkdir -p "${target_dir}/etc/obake"
{
	printf 'flavor=rt\n'
	printf 'arch=%s\n' "$arch"
	printf 'image=%s\n' "$kver"
} >"${target_dir}/etc/obake/kernel"
printf '%s\n' "$image_version" >"${target_dir}/etc/obake/image-version"

printf '[post-build] kernel=%s arch=%s image-version=%s\n' \
	"$kver" "$arch" "$image_version"
