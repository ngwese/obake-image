#!/usr/bin/env bash
set -euo pipefail

# End-to-end integration verification on x86_64:
#   install (installer) -> customize -> update -> reboot -> forced failed
#   update -> revert, asserting the writable contract and that the user
#   partition is never modified by the update/revert.
#
# Usage: integration-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../.." && pwd)"
arch="${1:-amd64}"
out="${OUT_BASE:-$project_root/dist/verify/$arch/integration}"
timeout_s="${INSTALL_TIMEOUT:-900}"
boot_timeout="${INTEGRATION_BOOT_TIMEOUT:-300}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

log() { printf '[integration] %s\n' "$*" >&2; }
fail() { printf '[integration] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "generating signing material"
"$project_root/os/scripts/make-signing-material.sh" "$out/trusted" >/dev/null
keyring="$out/trusted/ca.cert.pem"
sign_cert="$out/trusted/signing.cert.pem"
sign_key="$out/trusted/signing.key"

bundle() { # bundle <artifacts> <slot> <version> <out.raucb>
  RAUC_SIGNING_CERT="$sign_cert" RAUC_SIGNING_KEY="$sign_key" \
    "$project_root/os/scripts/make-bundle.sh" "$2" "$3" \
    "$1/root-$2.img" "$1/obake-$2.efi" "$(dirname "$4")" >/dev/null
  mv "$(dirname "$4")/obake-$3-$2.raucb" "$4"
}

log "building bad update artifacts (mock_health=fail)"
ARCH="$arch" VERSION=0.6.0 MOCK_HEALTH=fail HEALTH_MAX_ATTEMPTS=1 \
  VERIFY=1 VERIFY_INTEGRATION=1 RAUC_KEYRING="$keyring" \
  OUT="$out/bad" "$project_root/os/build.sh" >"$out/bad-build.log" 2>&1
# The bad update targets slot A (the inactive slot while running the good slot).
bundle "$out/bad" a 0.6.0 "$out/bad.raucb"

log "building good update artifacts (mock_health=pass) with the bad bundle"
ARCH="$arch" VERSION=0.5.0 MOCK_HEALTH=pass HEALTH_MAX_ATTEMPTS=3 \
  VERIFY=1 VERIFY_INTEGRATION=1 RAUC_KEYRING="$keyring" \
  VERIFY_INTEGRATION_BAD="$out/bad.raucb" \
  OUT="$out/good" "$project_root/os/build.sh" >"$out/good-build.log" 2>&1
# The good update targets slot B (the inactive slot while running the base slot).
bundle "$out/good" b 0.5.0 "$out/good.raucb"

log "building installed image and installer (with both bundles)"
ARCH="$arch" VERSION=0.0.0 MOCK_HEALTH=pass HEALTH_MAX_ATTEMPTS=3 \
  VERIFY=1 VERIFY_INTEGRATION=1 RAUC_KEYRING="$keyring" \
  VERIFY_INTEGRATION_GOOD="$out/good.raucb" \
  MAKE_INSTALLER=1 OUT="$out/image" \
  "$project_root/os/build.sh" >"$out/image-build.log" 2>&1

installer="$out/image/installer.img"
target="$out/target.img"
rm -f "$target"
qemu-img create -f raw "$target" 16G >/dev/null

run_installer() {
  local vars
  vars="$(mktemp)"
  cp "$ovmf_vars" "$vars"
  set +e
  timeout "$timeout_s" qemu-system-x86_64 \
    -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
    -m 2048 -smp "$OBKA_QEMU_SMP" -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$vars" \
    -drive if=none,id=inst,format=raw,file="$installer","$OBKA_QEMU_DISK_OPTS" \
    -device virtio-blk-pci,drive=inst,bootindex=0 \
    -drive if=none,id=tgt,format=raw,file="$target","$OBKA_QEMU_DISK_OPTS" \
    -device virtio-blk-pci,drive=tgt,bootindex=1 \
    -nographic >"$out/install.log" 2>&1
  set -e
  rm -f "$vars"
}

log "installing (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
run_installer
grep -qF "OBKA_INSTALL_DONE" "$out/install.log" || fail "install did not complete"

# Trigger the integration service by placing the state file on the target's
# persist partition (which the installer seeded).
log "seeding integration state on the persist partition"
read -r pstart pend < <(sgdisk -i 4 "$target" |
  awk '/First sector/{s=$3} /Last sector/{e=$3} END{print s, e}')
part="$out/persist.img"
dd if="$target" of="$part" bs=512 skip="$pstart" count=$((pend - pstart + 1)) status=none
printf '1\n' >"$out/state.txt"
debugfs -w -R "write $out/state.txt /obake-integration" "$part" >/dev/null 2>&1 ||
  fail "could not seed integration state"
dd if="$part" of="$target" bs=512 seek="$pstart" conv=notrunc status=none

efi_vars="$out/boot-vars.fd"
cp "$ovmf_vars" "$efi_vars"
log_file="$out/integration.log"
: >"$log_file"

boot() {
  log "booting phase ${1} (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
  set +e
  timeout "$boot_timeout" qemu-system-x86_64 \
    -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
    -m 2048 -smp "$OBKA_QEMU_SMP" -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$efi_vars" \
    -drive file="$target",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
    -nographic >>"$log_file" 2>&1
  set -e
}

boot 1
boot 2
boot 3
boot 4

for marker in OBKA_INTEGRATION_PHASE1_PASS OBKA_INTEGRATION_PHASE2_PASS \
  OBKA_INTEGRATION_PHASE3_REACHED OBKA_INTEGRATION_PASS; do
  grep -qF "$marker" "$log_file" || fail "missing $marker; see $log_file"
done
printf 'PASS: install, update, failed update, and revert integration\n'
