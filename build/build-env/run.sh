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
# cache so repeated builds are incremental and offline. The container runs as
# the invoking user so staged outputs are user-owned.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../../.." && pwd)"
image="${OBKA_BUILD_IMAGE:-obake-buildroot-env}"
volume="${OBKA_BUILD_VOLUME:-obake-buildroot-cache}"
uid="$(id -u)"
gid="$(id -g)"

if ! docker buildx version >/dev/null 2>&1; then
	printf '[build-env] error: Docker Buildx is required to build this image.\n' >&2
	printf 'Install the Docker Buildx CLI plugin (Ubuntu: apt install docker-buildx).\n' >&2
	exit 1
fi
docker buildx build -q -t "$image" "$here" >/dev/null

docker volume create "$volume" >/dev/null

# Bootstrap cache ownership once when the invoking user cannot write it.
if ! docker run --rm --user "$uid:$gid" -v "$volume":/cache "$image" \
	sh -c 'touch /cache/.obake-write-test && rm -f /cache/.obake-write-test' \
	>/dev/null 2>&1; then
	docker run --rm -u 0 -v "$volume":/cache "$image" \
		chown -R "$uid:$gid" /cache >/dev/null
fi

# Forward the build knobs the harnesses set.
forward=()
for v in VERIFY VERIFY_HEALTH VERIFY_PERSIST VERIFY_UPDATE VERIFY_INTEGRATION \
	VERIFY_UPDATE_BUNDLE VERIFY_INTEGRATION_GOOD VERIFY_INTEGRATION_BAD \
	VERIFY_INTEGRATION_SEED \
	BREAK MAKE_DISK MAKE_INSTALLER MAKE_BUNDLE BUNDLE_SLOT IMAGE_TAG OBAKE_IMAGE_VERSION \
	OBKA_IMAGE_VERSION OBKA_SSH_AUTHORIZED_KEY OBKA_PASSWORD \
	OBKA_SINGULARITY_STAGE \
	OBKA_SINGULARITY_VERSION RAUC_SIGNING_CERT RAUC_SIGNING_KEY RAUC_KEYRING \
	USER_SIZE_MIB SUITE MIRROR SECURITY_SUITE LAYOUT DISK_SLOT \
	CONSOLE INSTALLER_TARGET_DISK INSTALLER_PRESERVE_USER \
	INSTALLER_POWEROFF_DELAY \
	MOCK_HEALTH HEALTH_MAX_ATTEMPTS LOCAL_BUNDLE UPDATE_URL \
	OBAKE_BOARD OBAKE_PROFILE OBAKE_OUT; do
	[ -n "${!v:-}" ] && forward+=(-e "$v=${!v}")
done

# Non-login bash so /etc/profile cannot drop /usr/sbin from PATH (sgdisk lives
# there). The invoking uid may not exist in the image passwd database; give
# Buildroot a writable HOME on the cache volume.
bootstrap='
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p "$HOME"
if [ ! -d /cache/dl ] && [ -d /work/image/os/buildroot/vendor/dl ]; then
  cp -a /work/image/os/buildroot/vendor/dl /cache/dl
fi
exec "$@"
'

exec docker run --rm \
	--user "$uid:$gid" \
	-v "$project_root":/work \
	-v "$volume":/cache \
	-w /work \
	"${forward[@]+"${forward[@]}"}" \
	-e "HOME=/cache/home" \
	-e "OBAKE_WORK=${OBAKE_WORK:-/cache/buildroot}" \
	-e "DL_DIR=${DL_DIR:-/cache/dl}" \
	-e FORCE_UNSAFE_CONFIGURE=1 \
	"$image" \
	bash -c "$bootstrap" _ "$@"
