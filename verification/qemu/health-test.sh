#!/usr/bin/env bash
set -euo pipefail

# Health-gate verification. Builds an image whose updated slot has a mock
# positive or negative health check, installs a bundle, and boots repeatedly
# with persistent EFI variables.
#
# Usage: health-test.sh [pass|revert] [arch]
#   pass    a healthy updated slot is marked good
#   revert  a persistently unhealthy update is reverted and its configuration
#           restored

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../.." && pwd)"
mode="${1:-pass}"
arch="${2:-amd64}"

out="$project_root/dist/verify/$arch/health-$mode"
bundle_version="0.4.0"
boot_timeout="${HEALTH_BOOT_TIMEOUT:-300}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

log() { printf '[health-test] %s\n' "$*" >&2; }
fail() { printf '[health-test] FAIL: %s\n' "$*" >&2; exit 1; }

if [ "$mode" = "revert" ]; then
  mock_health="fail"
  max_attempts=1
else
  mock_health="pass"
  max_attempts=3
fi

rm -rf "$out"
mkdir -p "$out"

log "building update OS artifacts (mock_health=$mock_health, max_attempts=$max_attempts)"
ARCH="$arch" VERSION="$bundle_version" IMAGE_TAG="$bundle_version" \
  VERIFY=1 VERIFY_HEALTH=1 MOCK_HEALTH="$mock_health" \
  HEALTH_MAX_ATTEMPTS="$max_attempts" OUT="$out/update-artifacts" \
  "$project_root/os/build.sh" >"$out/update-artifacts-build.log" 2>&1

os/scripts/make-signing-material.sh "$out/trusted" >/dev/null
RAUC_SIGNING_CERT="$out/trusted/signing.cert.pem" \
  RAUC_SIGNING_KEY="$out/trusted/signing.key" \
  "$project_root/os/scripts/make-bundle.sh" b "$bundle_version" \
  "$out/update-artifacts/root-b.img" "$out/update-artifacts/obake-b.efi" \
  "$out/bundles" >/dev/null

log "building verification image for mode $mode"
RAUC_KEYRING="$out/trusted/ca.cert.pem" VERIFY=1 VERIFY_HEALTH=1 MAKE_DISK=1 \
  VERIFY_UPDATE_BUNDLE="$out/bundles/obake-$bundle_version-b.raucb" \
  LOCAL_BUNDLE="/opt/obake/update.raucb" \
  MOCK_HEALTH="$mock_health" HEALTH_MAX_ATTEMPTS="$max_attempts" \
  ARCH="$arch" OUT="$out/image" "$project_root/os/build.sh" \
  >"$out/build.log" 2>&1

disk="$out/image/disk-a.img"
efi_vars="$out/vars.fd"
cp "$ovmf_vars" "$efi_vars"
log_file="$out/health.log"
: >"$log_file"

boot() {
  log "booting ${1} (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
  set +e
  timeout "$boot_timeout" qemu-system-x86_64 \
    -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
    -m 4096 -smp "$OBKA_QEMU_SMP" -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$efi_vars" \
    -drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
    -nographic >>"$log_file" 2>&1
  set -e
}

boot 1
boot 2
[ "$mode" = "revert" ] && boot 3

grep -qF "OBKA_HEALTH_PHASE1_PASS" "$log_file" ||
  fail "update client did not snapshot/mark pending"

if [ "$mode" = "pass" ]; then
  grep -qF "OBKA_HEALTH_PASS" "$log_file" || fail "healthy slot was not marked good"
  printf 'PASS: healthy update marked good (%s)\n' "$mode"
  exit 0
fi

grep -qF "OBKA_HEALTH_REVERT" "$log_file" || fail "unhealthy update was not reverted"
grep -qF "OBKA_HEALTH_TEST_BOOT booted=rootfs.0" "$log_file" ||
  fail "did not fall back to the previous slot"
grep -qF "OBKA_HEALTH_CONFIG_RESTORED" "$log_file" ||
  fail "previous configuration was not restored"
printf 'PASS: unhealthy update reverted and configuration restored (%s)\n' "$mode"
