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
# Guest RAM in MiB. qemu-user emulation (the emulated linux/amd64 container on
# macOS) cannot allocate a 2 GiB guest; set OBKA_QEMU_MEM=1024 there.
OBKA_QEMU_MEM="${OBKA_QEMU_MEM:-2048}"
# Convenience: the disk cache/aio options applied to every block device.
OBKA_QEMU_DISK_OPTS="cache=${OBKA_QEMU_CACHE},aio=${OBKA_QEMU_AIO}"

# OVMF/EDK2 firmware. Linux distributions install it under /usr/share/OVMF;
# Homebrew's QEMU ships EDK2 with the emulator under its share directory.
if [ "$(uname -s)" = "Darwin" ]; then
	qemu_share="$(brew --prefix qemu 2>/dev/null || printf /opt/homebrew/opt/qemu)/share/qemu"
	OVMF_CODE="${OVMF_CODE:-$qemu_share/edk2-x86_64-code.fd}"
	OVMF_VARS="${OVMF_VARS:-$qemu_share/edk2-i386-vars.fd}"
fi

# coreutils `timeout` is absent on macOS. Provide a minimal shim so the
# harnesses run natively there, where a single-translation (native arm64 QEMU)
# TCG guest boots far faster than under qemu-user nested emulation.
if ! command -v timeout >/dev/null 2>&1; then
	timeout() {
		local duration="$1"; shift
		"$@" &
		local cmd_pid=$!
		( sleep "$duration"; kill -TERM "$cmd_pid" 2>/dev/null ) &
		local watcher_pid=$!
		wait "$cmd_pid"; local rc=$?
		kill "$watcher_pid" 2>/dev/null
		wait "$watcher_pid" 2>/dev/null
		return "$rc"
	}
fi

export OBKA_QEMU_ACCEL_NAME OBKA_QEMU_CPU OBKA_QEMU_AIO OBKA_QEMU_CORES
export OBKA_QEMU_CACHE OBKA_QEMU_SMP OBKA_QEMU_DISK_OPTS OBKA_QEMU_MEM
export OVMF_CODE OVMF_VARS
