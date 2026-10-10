#!/usr/bin/env bash
# Run a verification harness inside the native QEMU verification environment.
#
# The harnesses normally run on a verify host that has QEMU/OVMF installed. On a
# host without them (no system QEMU, or no permission to install one) this
# wrapper runs the same harnesses unchanged inside a container that provides
# QEMU, OVMF/EDK2, the disk tools, and `rauc`. It mounts the repository at its
# real path, the host's Docker socket (so a harness can still ask
# `../build.sh` to build artifacts in the Buildroot build container), and the
# host's KVM device, so verification runs accelerated.
#
# The container runs as the invoking user so writes under image/_verify and
# image/_dev are user-owned. When /dev/kvm or /var/run/docker.sock exist, their
# host owning groups are added so acceleration and nested builds keep working.
#
# Usage: run.sh <command> [args...]
#
#   image/verification/verify-env/run.sh image/verification/qemu/integration-test.sh x86_64
#
# Override the image with OBKA_VERIFY_IMAGE and the build knobs with the usual
# OBKA_* / VERIFY* / BREAK / RAUC_* environment variables (forwarded below).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../../.." && pwd)"
image_root="$(cd "$here/../.." && pwd)"
image="${OBKA_VERIFY_IMAGE:-obake-verify-env}"
uid="$(id -u)"
gid="$(id -g)"

if [ $# -lt 1 ]; then
	printf 'usage: %s <command> [args...]\n' "$0" >&2
	exit 2
fi

docker build -q -t "$image" "$here" >/dev/null

# Reclaim leftover foreign-owned trees so harnesses can rm -rf without sudo.
bash "$here/../ensure-user-owned.sh" \
	"$image_root/_verify" "$image_root/_dev" || true

run_args=(--rm
	--user "$uid:$gid"
	-e "HOME=/tmp"
	-v "$project_root:$project_root"
	-w "$project_root")

# Supplementary groups for devices the non-root user must still access.
add_owner_group() {
	local path="$1" g
	[ -e "$path" ] || return 0
	g="$(stat -c '%g' "$path" 2>/dev/null || stat -f '%g' "$path")"
	[ -n "$g" ] && run_args+=(--group-add "$g")
}
add_owner_group /dev/kvm
add_owner_group /var/run/docker.sock

# KVM acceleration when the host exposes it.
[ -e /dev/kvm ] && run_args+=(--device=/dev/kvm)

# Let a harness invoke the Buildroot build container through image/build/build.sh.
if [ -S /var/run/docker.sock ]; then
	run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi
if [ -x /usr/bin/docker ]; then
	run_args+=(-v /usr/bin/docker:/usr/local/bin/docker:ro)
fi

# Forward the harness and build knobs; unset variables are skipped.
for v in \
	OBKA_ARCH OBKA_REBUILD OBKA_ARTIFACTS \
	OBKA_QEMU_BIN OBKA_QEMU_ACCEL OBKA_QEMU_CPU OBKA_QEMU_MEM \
	OBKA_QEMU_CORES OBKA_QEMU_CACHE \
	OVMF_CODE OVMF_VARS LAYOUT OUT_BASE \
	VERIFY VERIFY_HEALTH VERIFY_PERSIST VERIFY_UPDATE VERIFY_INTEGRATION \
	VERIFY_UPDATE_BUNDLE VERIFY_INTEGRATION_GOOD VERIFY_INTEGRATION_BAD \
	BREAK MAKE_DISK MAKE_INSTALLER MAKE_BUNDLE IMAGE_TAG \
	OBAKE_IMAGE_VERSION OBKA_IMAGE_VERSION \
	RAUC_SIGNING_CERT RAUC_SIGNING_KEY RAUC_KEYRING \
	USER_SIZE_MIB DISK_SLOT OBKA_SSH_AUTHORIZED_KEY OBKA_PASSWORD \
	MOCK_HEALTH HEALTH_MAX_ATTEMPTS LOCAL_BUNDLE UPDATE_URL \
	DL_DIR OBAKE_BUILD_IMAGE OBAKE_BUILD_VOLUME OBKA_BUILD_IMAGE OBKA_BUILD_VOLUME \
	INSTALL_TIMEOUT INSTALL_WORK INSTALL_MARKER INSTALL_LOG \
	INSTALL_TARGET_DISK INSTALL_PRESERVE_USER \
	BOOT_TIMEOUT BOOT_LOG BOOT_MARKER PERSIST_BOOT_TIMEOUT \
	UPDATE_BOOT_TIMEOUT HEALTH_BOOT_TIMEOUT INTEGRATION_BOOT_TIMEOUT \
	INTEGRATION_DISK_SIZE INTEGRATION_BASE_VERSION \
	INTEGRATION_GOOD_VERSION INTEGRATION_BAD_VERSION \
	SSH_TEST_PORT SSH_BOOT_TIMEOUT PASSWORD_TEST_PORT OBKA_TEST_PASSWORD; do
	[ -n "${!v:-}" ] && run_args+=(-e "$v=${!v}")
done

set +e
docker run "${run_args[@]}" "$image" "$@"
rc=$?
set -e

# Safety net if anything was still written with foreign ownership.
bash "$here/../ensure-user-owned.sh" \
	"$image_root/_verify" "$image_root/_dev" || true

exit "$rc"
