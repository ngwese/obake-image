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
#   OBKA_ARTIFACTS use a specific artifact directory instead of dist/os/<arch>

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../../.." && pwd)"

# obka_arch_dir [arch] -> artifact directory path for the architecture.
obka_arch_dir() {
	local a="${1:-native}"
	case "$a" in
	'' | native) printf '%s' "$project_root/dist/os/$OBKA_ARCH" ;;
	amd64 | x86_64) printf '%s' "$project_root/dist/os/x86_64" ;;
	arm64 | aarch64) printf '%s' "$project_root/dist/os/aarch64" ;;
	*) printf '%s' "$project_root/dist/os/$a" ;;
	esac
}

# obka_build [arch] -> builds if needed and prints the artifact directory.
obka_build() {
	local arch="${1:-native}" dir
	if [ -n "${OBKA_ARTIFACTS:-}" ]; then
		printf '%s' "$OBKA_ARTIFACTS"
		return
	fi
	dir="$(obka_arch_dir "$arch")"
	if [ ! -f "$dir/disk-a.img" ] || [ "${OBKA_REBUILD:-0}" = "1" ]; then
		( cd "$project_root/image/verification" && ./build.sh "$arch" "$dir" ) >&2
	fi
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
		"$@" -nographic >>"$log" 2>&1
	local rc=$?
	set -e
	return $rc
}
