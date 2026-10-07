#!/usr/bin/env bash
# Run a command inside the native obake Buildroot build environment.
#
# The container is native to the host architecture (arm64 on Apple silicon) and
# cross-compiles the target; it has no QEMU/OVMF, so verification runs elsewhere
# against the artifacts this container produces (see ../README.md).
#
# Usage: run.sh <command> [args...]
#
# A persistent volume caches the Buildroot work tree and the vendored download
# cache so repeated builds are incremental and offline.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../../.." && pwd)"
image="${OBKA_BUILD_IMAGE:-obake-buildroot-env}"
volume="${OBKA_BUILD_VOLUME:-obake-buildroot-cache}"

docker build -q -t "$image" "$here" >/dev/null

docker volume create "$volume" >/dev/null

# Forward the build knobs the harnesses set.
forward=()
for v in VERIFY VERIFY_HEALTH VERIFY_PERSIST VERIFY_UPDATE VERIFY_INTEGRATION \
	VERIFY_UPDATE_BUNDLE VERIFY_INTEGRATION_GOOD VERIFY_INTEGRATION_BAD \
	BREAK MAKE_DISK MAKE_INSTALLER MAKE_BUNDLE IMAGE_TAG OBAKE_IMAGE_VERSION \
	OBKA_IMAGE_VERSION OBKA_SSH_AUTHORIZED_KEY OBKA_SINGULARITY_STAGE \
	OBKA_SINGULARITY_VERSION RAUC_SIGNING_CERT RAUC_SIGNING_KEY RAUC_KEYRING \
	USER_SIZE_MIB SUITE MIRROR SECURITY_SUITE LAYOUT DISK_SLOT \
	INSTALLER_TARGET_DISK INSTALLER_PRESERVE_USER \
	MOCK_HEALTH HEALTH_MAX_ATTEMPTS LOCAL_BUNDLE UPDATE_URL; do
	[ -n "${!v:-}" ] && forward+=(-e "$v=${!v}")
done

seed_dl='
if [ ! -d /cache/dl ] && [ -d /work/image/os/buildroot/vendor/dl ]; then
  cp -a /work/image/os/buildroot/vendor/dl /cache/dl
fi
'

exec docker run --rm \
	-v "$project_root":/work \
	-v "$volume":/cache \
	-w /work \
	"${forward[@]+"${forward[@]}"}" \
	-e "OBAKE_WORK=${OBAKE_WORK:-/cache/buildroot}" \
	-e "DL_DIR=${DL_DIR:-/cache/dl}" \
	-e FORCE_UNSAFE_CONFIGURE=1 \
	"$image" \
	bash -lc "${seed_dl} exec \"\$@\"" _ "$@"
