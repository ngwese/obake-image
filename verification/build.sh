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
else
	export LAYOUT="${LAYOUT:-$project_root/image/os/partition-layout.verify.json}"
	work="${OBAKE_WORK:-$project_root/image/.build/buildroot}"
	OBAKE_WORK="$work" DL_DIR="${DL_DIR:-$project_root/image/os/buildroot/vendor/dl}" \
		bash "$project_root/image/os/buildroot/build.sh" "$defconfig"
	cp -a "$work/output/$defconfig/images/." "$out/"
fi

printf '%s\n' "$out"
