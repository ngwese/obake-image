#!/usr/bin/env bash
# Build an obake Buildroot image and stage its artifacts for verification.
#
# Usage: build.sh [arch] [outdir]
#
#   arch    native (default) | amd64 | arm64
#   outdir  artifact directory (default dist/os/<arch>)
#
# Build knobs (VERIFY*, BREAK, MAKE_DISK, MAKE_INSTALLER, IMAGE_TAG,
# RAUC_SIGNING_*, OBKA_SSH_AUTHORIZED_KEY, ...) are forwarded to the build.
#
# On a host with Docker the build runs in the native build container and the
# artifacts are streamed out with tar (preserving sparse disk images). On a
# Linux host without Docker the Buildroot build runs directly.
#
# Prints the artifact directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../.." && pwd)"

arch_arg="${1:-native}"
case "$arch_arg" in
native)
	case "$(uname -m)" in
	arm64 | aarch64) arch=aarch64 ;;
	*) arch=x86_64 ;;
	esac
	;;
amd64 | x86_64) arch=x86_64 ;;
arm64 | aarch64) arch=aarch64 ;;
*) arch="$arch_arg" ;;
esac
defconfig="obake_${arch}_defconfig"
out="${2:-$project_root/dist/os/$arch}"

mkdir -p "$out"

if command -v docker >/dev/null 2>&1; then
	work_in_container="${OBAKE_WORK:-/cache/buildroot}"
	volume="${OBKA_BUILD_VOLUME:-obake-buildroot-cache}"
	image="${OBKA_BUILD_IMAGE:-obake-buildroot-env}"
	# Verification uses small disk images so they can be staged on a laptop; the
	# release build uses the real partition-layout.json.
	export LAYOUT="${LAYOUT:-/work/image/os/partition-layout.verify.json}"
	# Translate input paths under the repo to their container-visible form.
	for v in RAUC_SIGNING_CERT RAUC_SIGNING_KEY RAUC_KEYRING VERIFY_UPDATE_BUNDLE \
		VERIFY_INTEGRATION_GOOD VERIFY_INTEGRATION_BAD OBKA_SSH_AUTHORIZED_KEY; do
		val="${!v:-}"
		[ -n "$val" ] || continue
		export "$v=$(printf '%s' "$val" | sed "s#^$project_root#/work#")"
	done
	# MAKE_DISK defaults to 1 so the disk images the harnesses boot exist.
	"$here/build-env/run.sh" bash -lc "
		set -e
		bash image/os/buildroot/build.sh $defconfig
	"
	# Stage the images directory onto the host.
	ctr="$(docker create -v "$volume":/cache "$image" true)"
	rm -rf "$out"
	mkdir -p "$out"
	docker cp "$ctr":"$work_in_container/output/$defconfig/images/." "$out/"
	docker rm "$ctr" >/dev/null
	# Drop the large derived images from the cache tree; they are regenerated
	# each build and would otherwise accumulate in the build volume.
	docker run --rm -v "$volume":/cache "$image" sh -c \
		"rm -rf $work_in_container/output/$defconfig/images/disk-*.img \
			$work_in_container/output/$defconfig/images/.disk-work \
			$work_in_container/output/$defconfig/images/.installer" >/dev/null 2>&1 || true
else
	export LAYOUT="${LAYOUT:-$project_root/image/os/partition-layout.verify.json}"
	work="${OBAKE_WORK:-$project_root/image/.build/buildroot}"
	OBAKE_WORK="$work" DL_DIR="${DL_DIR:-$project_root/image/os/buildroot/vendor/dl}" \
		bash "$project_root/image/os/buildroot/build.sh" "$defconfig"
	cp -a "$work/output/$defconfig/images/." "$out/"
fi

printf '%s\n' "$out"
