#!/usr/bin/env bash
# Shared QEMU launch settings for the obake verification harnesses.
#
# Architecture-aware: the target architecture is chosen by OBKA_ARCH (default:
# aarch64 on arm64 hosts, x86_64 otherwise) so the same harnesses run the
# aarch64 image as a proxy for arm64 hardware, or the x86_64 image.
#
# Hardware acceleration is auto-detected and preferred over software emulation:
#   - HVF   on macOS (Hypervisor.framework; arm64 guests on Apple silicon)
#   - KVM   on Linux, including Windows 11 WSL2 with nested virtualization
#   - TCG   software emulation as a last resort
#
# Harnesses are headless (serial on stdio). Override any value with the matching
# OBKA_QEMU_* / OBKA_ARCH environment variable.

_obka_norm_arch() {
	case "${OBKA_ARCH:-}" in
	aarch64 | arm64) printf 'aarch64' ;;
	x86_64 | amd64) printf 'x86_64' ;;
	'')
		case "$(uname -m)" in
		arm64 | aarch64) printf 'aarch64' ;;
		*) printf 'x86_64' ;;
		esac
		;;
	*) printf '%s' "$OBKA_ARCH" ;;
	esac
}
OBKA_ARCH="$(_obka_norm_arch)"

OBKA_QEMU_BIN="${OBKA_QEMU_BIN:-qemu-system-$OBKA_ARCH}"
if [ "$OBKA_ARCH" = "aarch64" ]; then
	OBKA_QEMU_MACHINE_ARGS="-machine virt"
else
	OBKA_QEMU_MACHINE_ARGS="-machine q35"
fi

_obka_qemu_accel_name() {
	if [ -n "${OBKA_QEMU_ACCEL:-}" ]; then
		printf '%s' "$OBKA_QEMU_ACCEL"
		return
	fi
	local avail
	avail="$("$OBKA_QEMU_BIN" -accel help 2>/dev/null || true)"
	if [ "$(uname -s)" = "Darwin" ] && printf '%s\n' "$avail" | grep -qx hvf; then
		printf 'hvf'
	elif [ -e /dev/kvm ] && printf '%s\n' "$avail" | grep -qx kvm; then
		printf 'kvm'
	elif printf '%s\n' "$avail" | grep -qx whpx; then
		printf 'whpx'
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
		OBKA_QEMU_AIO="${OBKA_QEMU_AIO:-threads}"
	fi
fi
OBKA_QEMU_CORES="${OBKA_QEMU_CORES:-4}"
OBKA_QEMU_CACHE="${OBKA_QEMU_CACHE:-none}"
OBKA_QEMU_SMP="cores=${OBKA_QEMU_CORES},threads=1,sockets=1"
OBKA_QEMU_MEM="${OBKA_QEMU_MEM:-2048}"
OBKA_QEMU_DISK_OPTS="cache=${OBKA_QEMU_CACHE},aio=${OBKA_QEMU_AIO}"

# EDK2/OVMF firmware. Homebrew's QEMU ships it under its share directory;
# Linux distributions install it under /usr/share/OVMF or /usr/share/qemu.
_obka_fw_code() {
	if [ "$OBKA_ARCH" = "aarch64" ]; then printf '%s/edk2-aarch64-code.fd' "$1"; else printf '%s/edk2-x86_64-code.fd' "$1"; fi
}
_obka_fw_vars() {
	if [ "$OBKA_ARCH" = "aarch64" ]; then printf '%s/edk2-arm-vars.fd' "$1"; else printf '%s/edk2-i386-vars.fd' "$1"; fi
}
if [ -z "${OVMF_CODE:-}" ]; then
	for d in \
		"$(brew --prefix qemu 2>/dev/null)/share/qemu" \
		/opt/homebrew/share/qemu /opt/homebrew/opt/qemu/share/qemu \
		/usr/share/OVMF /usr/share/qemu /usr/share/edk2/aarch64 /usr/share/edk2/x64; do
		[ -f "$(_obka_fw_code "$d")" ] || continue
		OVMF_CODE="$(_obka_fw_code "$d")"
		[ -n "${OVMF_VARS:-}" ] || OVMF_VARS="$(_obka_fw_vars "$d")"
		break
	done
fi
OVMF_CODE="${OVMF_CODE:?OVMF/EDK2 firmware code not found; set OVMF_CODE}"
[ -f "$OVMF_VARS" ] || OVMF_VARS="$OVMF_CODE.vars"
# A writable variable store is created per run from this template.
OBKA_QEMU_FW_ARGS="-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE"

# coreutils `timeout` is absent on macOS. Provide a minimal shim so the
# harnesses run natively there.
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

export OBKA_ARCH OBKA_QEMU_BIN OBKA_QEMU_MACHINE_ARGS OBKA_QEMU_ACCEL_NAME
export OBKA_QEMU_CPU OBKA_QEMU_AIO OBKA_QEMU_CORES OBKA_QEMU_CACHE
export OBKA_QEMU_SMP OBKA_QEMU_DISK_OPTS OBKA_QEMU_MEM OBKA_QEMU_FW_ARGS
export OVMF_CODE OVMF_VARS
