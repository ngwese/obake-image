#!/usr/bin/env bash
set -euo pipefail

# Writable-contract persistence verification. Builds a verification disk,
# writes markers in one boot, reboots to confirm /etc and the persisted /var
# subset survive and transient /var is discarded, then switches slots and
# confirms they are retained. Run inside the build environment.
#
# Usage: persist-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../.." && pwd)"
arch="${1:-amd64}"
out="${OUT_BASE:-$project_root/dist/verify/$arch/persist}"
boot_timeout="${PERSIST_BOOT_TIMEOUT:-300}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

log() { printf '[persist-test] %s\n' "$*" >&2; }
fail() { printf '[persist-test] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "building verification image"
VERIFY=1 VERIFY_PERSIST=1 MAKE_DISK=1 ARCH="$arch" OUT="$out/image" \
  "$project_root/os/build.sh" >"$out/build.log" 2>&1

disk="$out/image/disk-a.img"
efi_vars="$out/vars.fd"
cp "$ovmf_vars" "$efi_vars"
log_file="$out/persist.log"
: >"$log_file"

boot() {
  log "booting ${1} (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
  set +e
  timeout "$boot_timeout" qemu-system-x86_64 \
    -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
    -m 2048 -smp "$OBKA_QEMU_SMP" -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$efi_vars" \
    -drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
    -nographic >>"$log_file" 2>&1
  set -e
}

boot 1
boot 2
boot 3

for phase in PHASE1 PHASE2 PHASE3; do
  grep -qF "OBKA_PERSIST_${phase}_PASS" "$log_file" ||
    fail "$phase did not pass; see $log_file"
done
printf 'PASS: writable contract persists across reboot and slot switch\n'
