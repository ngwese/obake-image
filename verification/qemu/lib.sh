#!/usr/bin/env bash
# Shared helpers for the obake QEMU verification harnesses.
#
# A harness builds (or reuses) a Buildroot artifact directory for the target
# architecture, then boots disk images from it under the host's QEMU. Build and
# verification are decoupled: the artifact directory is the interface.
#
# Environment:
#   OBKA_ARCH      aarch64 (default on arm64 hosts) | x86_64
#   OBKA_REBUILD   set to 1 to force a rebuild even if artifacts exist
#   OBKA_ARTIFACTS use a specific artifact directory instead of the default
#                  _out path for the board's virtual profile

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../../.." && pwd)"
image_root="$(cd "$here/../.." && pwd)"
buildsh="$project_root/image/build/build.sh"

# obka_board [arch] -> generic board for the architecture.
obka_board() {
	local a="${1:-native}"
	case "$a" in
	'' | native)
		case "$OBKA_ARCH" in
		aarch64) printf 'generic-aarch64' ;;
		*) printf 'generic-x86_64' ;;
		esac
		;;
	amd64 | x86_64) printf 'generic-x86_64' ;;
	arm64 | aarch64) printf 'generic-aarch64' ;;
	*) printf 'generic-%s' "$a" ;;
	esac
}

# obka_arch_dir [arch] -> artifact directory for the board's virtual profile.
obka_arch_dir() {
	local board
	board="$(obka_board "${1:-native}")"
	bash "$buildsh" --print-dir "$board" virtual
}

# obka_check_artifact_version <dir> -> fail unless pinned-inputs image_version
# matches the staged VERSION stamp.
obka_check_artifact_version() {
	local dir="${1:?usage: obka_check_artifact_version <artifact-dir>}"
	bash "$image_root/verification/check-artifact-version.sh" "$dir"
}

# obka_build [arch] -> builds the virtual profile if needed and prints the
# artifact directory.
obka_build() {
	local arch="${1:-native}" board dir
	if [ -n "${OBKA_ARTIFACTS:-}" ]; then
		obka_check_artifact_version "$OBKA_ARTIFACTS" >&2
		printf '%s' "$OBKA_ARTIFACTS"
		return
	fi
	board="$(obka_board "$arch")"
	dir="$(bash "$buildsh" --print-dir "$board" virtual)"
	if [ ! -f "$dir/disk-a.img" ] || [ "${OBKA_REBUILD:-0}" = "1" ]; then
		# Disk image for harnesses; --update skips installer unless overridden.
		MAKE_DISK=1 bash "$buildsh" "$board" virtual --update >&2
	fi
	obka_check_artifact_version "$dir" >&2
	printf '%s' "$dir"
}

# obka_boot <efi-vars> <disk> <log> <timeout> [extra qemu args...]
obka_boot() {
	local vars="$1" disk="$2" log="$3" timeout_s="$4"
	shift 4
	set +e
	# shellcheck disable=SC2086
	timeout "$timeout_s" "$OBKA_QEMU_BIN" \
		$OBKA_QEMU_MACHINE_ARGS -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
		-m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
		$OBKA_QEMU_FW_ARGS \
		-drive if=pflash,format=raw,file="$vars" \
		-drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
		-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
		"$@" -nographic >>"$log" 2>&1
	local rc=$?
	set -e
	return $rc
}
