#!/usr/bin/env bash
# Shared QEMU launch settings for the obake verification harnesses.
#
# Hardware acceleration is auto-detected and preferred over software emulation:
#   - KVM   on Linux, including Windows 11 WSL2 with nested virtualization
#   - WHPX  on Windows-native QEMU (Windows Hypervisor Platform)
#   - HAX   legacy Intel HAXM on Windows
#   - TCG   software emulation as a last resort
#
# When an accelerator is available the guest gets the host CPU model directly
# (-cpu host), the SMP topology is explicit (cores=,threads=1,sockets=1), and
# block devices use raw images with cache=none plus native AIO on KVM.
#
# These harnesses are headless (serial on stdio), so no GPU/SPICE device is
# configured.
#
# Override any of these with: OBKA_QEMU_ACCEL, OBKA_QEMU_CPU, OBKA_QEMU_CORES,
# OBKA_QEMU_CACHE, OBKA_QEMU_AIO.

_obka_qemu_accel_name() {
	if [ -n "${OBKA_QEMU_ACCEL:-}" ]; then
		printf '%s' "$OBKA_QEMU_ACCEL"
		return
	fi
	local avail
	avail="$(qemu-system-x86_64 -accel help 2>/dev/null || true)"
	if [ -e /dev/kvm ] && printf '%s\n' "$avail" | grep -qx kvm; then
		printf 'kvm'
	elif printf '%s\n' "$avail" | grep -qx whpx; then
		printf 'whpx'
	elif printf '%s\n' "$avail" | grep -qx hax; then
		printf 'hax'
	else
		printf 'tcg'
	fi
}

OBKA_QEMU_ACCEL_NAME="$(_obka_qemu_accel_name)"

if [ "$OBKA_QEMU_ACCEL_NAME" = "tcg" ]; then
	OBKA_QEMU_CPU="${OBKA_QEMU_CPU:-max}"
	OBKA_QEMU_AIO="${OBKA_QEMU_AIO:-threads}"
else
	OBKA_QEMU_CPU="${OBKA_QEMU_CPU:-host}"
	if [ "$OBKA_QEMU_ACCEL_NAME" = "kvm" ]; then
		OBKA_QEMU_AIO="${OBKA_QEMU_AIO:-native}"
	else
		# WHPX/HAX do not provide Linux native AIO.
		OBKA_QEMU_AIO="${OBKA_QEMU_AIO:-threads}"
	fi
fi
OBKA_QEMU_CORES="${OBKA_QEMU_CORES:-4}"
OBKA_QEMU_CACHE="${OBKA_QEMU_CACHE:-none}"
OBKA_QEMU_SMP="cores=${OBKA_QEMU_CORES},threads=1,sockets=1"
# Convenience: the disk cache/aio options applied to every block device.
OBKA_QEMU_DISK_OPTS="cache=${OBKA_QEMU_CACHE},aio=${OBKA_QEMU_AIO}"

export OBKA_QEMU_ACCEL_NAME OBKA_QEMU_CPU OBKA_QEMU_AIO OBKA_QEMU_CORES
export OBKA_QEMU_CACHE OBKA_QEMU_SMP OBKA_QEMU_DISK_OPTS
