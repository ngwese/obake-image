#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

installer="${1:?usage: install-test.sh <installer-image> [disk-size]}"
disk_size="${2:-16G}"
timeout_s="${INSTALL_TIMEOUT:-300}"
work="${INSTALL_WORK:-$here/install-work}"
install_marker="${INSTALL_MARKER:-OBKA_INSTALL_DONE}"
log="${INSTALL_LOG:-$here/install-test.log}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

[ -f "$installer" ] || { printf 'missing installer image: %s\n' "$installer" >&2; exit 2; }

mkdir -p "$work"
target="$work/target.img"
rm -f "$target"
qemu-img create -f raw "$target" "$disk_size" >/dev/null

vars="$(mktemp)"
cp "$ovmf_vars" "$vars"
trap 'rm -f "$vars"' EXIT

set +e
timeout "$timeout_s" qemu-system-x86_64 \
  -machine q35 -m 2048 -smp 2 -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$vars" \
  -drive file="$installer",format=raw,if=virtio \
  -drive file="$target",format=raw,if=virtio \
  -nographic -serial mon:stdio >"$log" 2>&1
status=$?
set -e

if ! grep -qF "$install_marker" "$log"; then
  printf 'FAIL: install marker %s not found (qemu exit %s); log: %s\n' "$install_marker" "$status" "$log" >&2
  exit 1
fi

printf 'PASS: install completed; booting installed disk\n'
exec "$here/boot-test.sh" "$target"
