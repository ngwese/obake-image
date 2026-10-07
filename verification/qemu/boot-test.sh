#!/usr/bin/env bash
set -euo pipefail

# Boot a disk image under UEFI firmware and assert a marker appears on the
# serial console. Architecture-aware: OBKA_ARCH selects aarch64 (default on
# arm64 hosts) or x86_64, and the matching EDK2/OVMF firmware and accelerator.
#
# Usage: boot-test.sh <disk-image> [marker]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

disk="${1:?usage: boot-test.sh <disk-image> [marker]}"
marker="${2:-${BOOT_MARKER:-login:}}"
timeout_s="${BOOT_TIMEOUT:-300}"
log="${BOOT_LOG:-$here/boot-test.log}"

[ -f "$disk" ] || { printf 'missing disk image: %s\n' "$disk" >&2; exit 2; }
[ -f "$OVMF_CODE" ] || { printf 'missing firmware code: %s\n' "$OVMF_CODE" >&2; exit 2; }
[ -f "$OVMF_VARS" ] || { printf 'missing firmware vars: %s\n' "$OVMF_VARS" >&2; exit 2; }

vars="$(mktemp)"
cp "$OVMF_VARS" "$vars"
trap 'rm -f "$vars"' EXIT

set +e
printf '[boot-test] arch=%s accel=%s cpu=%s smp=%s\n' \
	"$OBKA_ARCH" "$OBKA_QEMU_ACCEL_NAME" "$OBKA_QEMU_CPU" "$OBKA_QEMU_SMP" >&2
timeout "$timeout_s" "$OBKA_QEMU_BIN" \
	$OBKA_QEMU_MACHINE_ARGS -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
	-m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
	$OBKA_QEMU_FW_ARGS \
	-drive if=pflash,format=raw,file="$vars" \
	-drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
	-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
	-nographic >"$log" 2>&1
status=$?
set -e

if grep -qF "$marker" "$log"; then
	printf 'PASS: boot marker %s found\n' "$marker"
	exit 0
fi

printf 'FAIL: boot marker %s not found (qemu exit %s); log: %s\n' "$marker" "$status" "$log" >&2
exit 1
