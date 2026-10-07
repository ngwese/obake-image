#!/usr/bin/env bash
set -euo pipefail

# Installer verification: boot the installer medium and a blank target disk,
# wait for the install to complete, then boot the installed disk. The installed
# host must reuse the installer's EFI variables so it boots the EFI entries the
# installer created.
#
# Usage: install-test.sh [installer-image] [disk-size]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../../.." && pwd)"
arch_dir="$project_root/dist/os/$OBKA_ARCH"
installer="${1:-$arch_dir/installer.img}"
disk_size="${2:-8G}"
timeout_s="${INSTALL_TIMEOUT:-300}"
work="${INSTALL_WORK:-$here/install-work}"
install_marker="${INSTALL_MARKER:-OBKA_INSTALL_DONE}"
log="${INSTALL_LOG:-$here/install-test.log}"

log_fn() { printf '[install-test] %s\n' "$*" >&2; }

[ -f "$installer" ] || {
	( cd "$project_root/image/verification" && MAKE_INSTALLER=1 ./build.sh "$OBKA_ARCH" "$arch_dir" ) >&2
}
[ -f "$installer" ] || { printf 'missing installer image: %s\n' "$installer" >&2; exit 2; }

mkdir -p "$work"
target="$work/target.img"
rm -f "$target"
qemu-img create -f raw "$target" "$disk_size" >/dev/null

vars="$(mktemp)"
cp "$OVMF_VARS" "$vars"
trap 'rm -f "$vars"' EXIT

log_fn "installer boot (arch=$OBKA_ARCH accel=$OBKA_QEMU_ACCEL_NAME disk=$disk_size)"
set +e
# shellcheck disable=SC2086
timeout "$timeout_s" "$OBKA_QEMU_BIN" \
	$OBKA_QEMU_MACHINE_ARGS -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
	-m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
	$OBKA_QEMU_FW_ARGS \
	-drive if=pflash,format=raw,file="$vars" \
	-drive if=none,id=inst,format=raw,file="$installer","$OBKA_QEMU_DISK_OPTS" \
	-device virtio-blk-pci,drive=inst,bootindex=0 \
	-drive if=none,id=tgt,format=raw,file="$target","$OBKA_QEMU_DISK_OPTS" \
	-device virtio-blk-pci,drive=tgt,bootindex=1 \
	-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
	-nographic >"$log" 2>&1
status=$?
set -e

if ! grep -qF "$install_marker" "$log"; then
	printf 'FAIL: install marker %s not found (qemu exit %s); log: %s\n' "$install_marker" "$status" "$log" >&2
	exit 1
fi

printf 'PASS: install completed; booting installed disk\n'
if BOOT_TIMEOUT="$timeout_s" BOOT_LOG="$work/boot.log" OVMF_VARS="$vars" \
	"$here/boot-test.sh" "$target"; then
	printf 'PASS: installed host boots\n'
else
	printf 'FAIL: installed host did not boot; log: %s\n' "$work/boot.log" >&2
	exit 1
fi
