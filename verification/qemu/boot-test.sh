#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

disk="${1:?usage: boot-test.sh <disk-image> [marker]}"
marker="${2:-${BOOT_MARKER:-login:}}"
timeout_s="${BOOT_TIMEOUT:-180}"
log="${BOOT_LOG:-$here/boot-test.log}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

[ -f "$disk" ] || { printf 'missing disk image: %s\n' "$disk" >&2; exit 2; }
[ -f "$ovmf_code" ] || { printf 'missing OVMF code: %s\n' "$ovmf_code" >&2; exit 2; }
[ -f "$ovmf_vars" ] || { printf 'missing OVMF vars: %s\n' "$ovmf_vars" >&2; exit 2; }

vars="$(mktemp)"
cp "$ovmf_vars" "$vars"
trap 'rm -f "$vars"' EXIT

set +e
timeout "$timeout_s" qemu-system-x86_64 \
  -machine q35 -m 2048 -smp 2 -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$vars" \
  -drive file="$disk",format=raw,if=virtio \
  -nographic -serial mon:stdio >"$log" 2>&1
status=$?
set -e

if grep -qF "$marker" "$log"; then
  printf 'PASS: boot marker %s found\n' "$marker"
  exit 0
fi

printf 'FAIL: boot marker %s not found (qemu exit %s); log: %s\n' "$marker" "$status" "$log" >&2
exit 1
