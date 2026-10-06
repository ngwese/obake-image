#!/usr/bin/env bash
set -euo pipefail

# Reinstall verification: install to a target, write a marker into the user
# partition, reinstall over the same disk, and assert the user partition was
# preserved. Run inside the build environment.
#
# Usage: reinstall-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../.." && pwd)"
arch="${1:-amd64}"
out="${OUT_BASE:-$project_root/dist/verify/$arch/reinstall}"
timeout_s="${INSTALL_TIMEOUT:-900}"
marker="obake preserve me"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

log() { printf '[reinstall] %s\n' "$*" >&2; }
fail() { printf '[reinstall] FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$out"
log "building installer image"
INSTALLER_TARGET_DISK=/dev/vdb INSTALLER_PRESERVE_USER=1 MAKE_INSTALLER=1 \
  ARCH="$arch" OUT="$out/artifacts" "$project_root/os/build.sh" \
  >"$out/build.log" 2>&1

installer="$out/artifacts/installer.img"
target="$out/target.img"
rm -f "$target"
qemu-img create -f raw "$target" 16G >/dev/null

run_installer() { # run_installer <log>
  local logfile="$1" vars
  vars="$(mktemp)"
  cp "$ovmf_vars" "$vars"
  set +e
  printf '[reinstall] accel=%s cpu=%s smp=%s\n' \
    "$OBKA_QEMU_ACCEL_NAME" "$OBKA_QEMU_CPU" "$OBKA_QEMU_SMP" >&2
  timeout "$timeout_s" qemu-system-x86_64 \
    -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
    -m 2048 -smp "$OBKA_QEMU_SMP" -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$vars" \
    -drive if=none,id=inst,format=raw,file="$installer","$OBKA_QEMU_DISK_OPTS" \
    -device virtio-blk-pci,drive=inst,bootindex=0 \
    -drive if=none,id=tgt,format=raw,file="$target","$OBKA_QEMU_DISK_OPTS" \
    -device virtio-blk-pci,drive=tgt,bootindex=1 \
    -nographic >"$logfile" 2>&1
  local rc=$?
  set -e
  rm -f "$vars"
  return $rc
}

# Extract / reinstate the user partition (role order 5).
user_part_offsets() {
  sgdisk -i 5 "$target" |
    awk '/First sector/{s=$3} /Last sector/{e=$3} END{print s, e}'
}

inject_marker() {
  local part="$out/user-part.img" start end
  read -r start end < <(user_part_offsets)
  dd if="$target" of="$part" bs=512 skip="$start" count=$((end - start + 1)) status=none
  printf '%s\n' "$marker" >"$out/marker.txt"
  debugfs -w -R "write $out/marker.txt /home/obake-preserve-test" "$part" >/dev/null 2>&1 ||
    fail "could not write marker into user partition"
  dd if="$part" of="$target" bs=512 seek="$start" conv=notrunc status=none
}

check_marker() {
  local part="$out/user-part-check.img" start end got
  read -r start end < <(user_part_offsets)
  dd if="$target" of="$part" bs=512 skip="$start" count=$((end - start + 1)) status=none
  got="$(debugfs -R "cat /home/obake-preserve-test" "$part" 2>/dev/null)"
  [ "$got" = "$marker" ] || fail "user partition marker not preserved (got '$got')"
}

# Remove the installed target's removable-media fallback so firmware boots the
# installer on the second run (the installer reformats the ESP regardless).
disable_target_esp_boot() {
  local espimg="$out/esp.img" start end
  read -r start end < <(sgdisk -i 1 "$target" |
    awk '/First sector/{s=$3} /Last sector/{e=$3} END{print s, e}')
  dd if="$target" of="$espimg" bs=512 skip="$start" count=$((end - start + 1)) status=none
  mdel -i "$espimg" ::/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
  dd if="$espimg" of="$target" bs=512 seek="$start" conv=notrunc status=none
}

log "first install (fresh)"
run_installer "$out/install1.log" || true
grep -qF "OBKA_INSTALL_DONE" "$out/install1.log" || fail "first install did not complete"

log "writing marker into the user partition"
inject_marker

log "second install (reinstall, preserving user data)"
disable_target_esp_boot
run_installer "$out/install2.log" || true
grep -qF "OBKA_INSTALL_DONE" "$out/install2.log" || fail "reinstall did not complete"

check_marker
printf 'PASS: user partition preserved across reinstall\n'
