#!/usr/bin/env bash
set -euo pipefail

# End-to-end integration verification:
#   install (installer) -> customize -> update -> reboot -> forced failed
#   update -> revert, asserting the writable contract and that the user
#   partition is never modified by the update/revert.
#
# Build and verification are decoupled: each image is built with the
# verification build wrapper (which uses the Buildroot build container when
# Docker is available) and booted under the host's QEMU. The signed RAUC
# bundles are produced by the build itself (the post-image hook), and the
# installed image seeds the integration trigger on its first boot, so the
# harness needs no host `rauc`, `sgdisk`, or `debugfs` and runs on any verify
# host (including the macOS arm64 aarch64 proxy under HVF).
#
# Usage: integration-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

arch="${1:-native}"
board="$(obka_board "$arch")"
out="${OUT_BASE:-$image_root/_verify/$OBKA_ARCH/integration}"
timeout_s="${INSTALL_TIMEOUT:-900}"
boot_timeout="${INTEGRATION_BOOT_TIMEOUT:-400}"
scripts="$project_root/image/os/scripts"

base_version="${INTEGRATION_BASE_VERSION:-0.0.0}"
good_version="${INTEGRATION_GOOD_VERSION:-0.5.0}"
bad_version="${INTEGRATION_BAD_VERSION:-0.6.0}"
disk_size="${INTEGRATION_DISK_SIZE:-8G}"

log() { printf '[integration] %s\n' "$*" >&2; }
fail() { printf '[integration] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "generating signing material"
bash "$scripts/make-signing-material.sh" "$out/trusted" >/dev/null
keyring="$out/trusted/ca.cert.pem"
sign_cert="$out/trusted/signing.cert.pem"
sign_key="$out/trusted/signing.key"

# The bad update is a trusted but unhealthy image: the health gate must revert
# it. Its bundle targets slot A (the inactive slot while the good image runs),
# so its UKI cmdline selects OBKA_ROOT_A. It is built first so the good image
# can embed its bundle.
log "building bad update artifacts (mock_health=fail, version $bad_version)"
OBAKE_IMAGE_VERSION="$bad_version" IMAGE_TAG="$bad_version" MAKE_DISK=0 \
	VERIFY=1 VERIFY_INTEGRATION=1 \
	MOCK_HEALTH=fail HEALTH_MAX_ATTEMPTS=1 BUNDLE_SLOT=a \
	RAUC_KEYRING="$keyring" RAUC_SIGNING_CERT="$sign_cert" RAUC_SIGNING_KEY="$sign_key" \
	OBAKE_OUTDIR="$out/bad" bash "$buildsh" "$board" virtual \
	>"$out/bad-build.log" 2>&1
bad_bundle="$out/bad/obake-$bad_version-a.raucb"
[ -f "$bad_bundle" ] || fail "no bad bundle built ($bad_bundle)"

# The good image embeds the bad bundle so the post-update slot can install it.
# Its bundle targets slot B.
log "building good update artifacts (mock_health=pass, version $good_version)"
OBAKE_IMAGE_VERSION="$good_version" IMAGE_TAG="$good_version" MAKE_DISK=0 \
	VERIFY=1 VERIFY_INTEGRATION=1 \
	MOCK_HEALTH=pass HEALTH_MAX_ATTEMPTS=3 BUNDLE_SLOT=b \
	VERIFY_INTEGRATION_BAD="$bad_bundle" \
	RAUC_KEYRING="$keyring" RAUC_SIGNING_CERT="$sign_cert" RAUC_SIGNING_KEY="$sign_key" \
	OBAKE_OUTDIR="$out/good" bash "$buildsh" "$board" virtual \
	>"$out/good-build.log" 2>&1
good_bundle="$out/good/obake-$good_version-b.raucb"
[ -f "$good_bundle" ] || fail "no good bundle built ($good_bundle)"

# The installed base image embeds the good bundle and seeds the trigger.
log "building installed image and installer (base version $base_version)"
OBAKE_IMAGE_VERSION="$base_version" IMAGE_TAG="$base_version" \
	MOCK_HEALTH=pass HEALTH_MAX_ATTEMPTS=3 \
	VERIFY=1 VERIFY_INTEGRATION=1 VERIFY_INTEGRATION_SEED=1 \
	VERIFY_INTEGRATION_GOOD="$good_bundle" \
	RAUC_KEYRING="$keyring" \
	MAKE_INSTALLER=1 CONSOLE=serial INSTALLER_POWEROFF_DELAY=0 \
	OBAKE_OUTDIR="$out/image" bash "$buildsh" "$board" virtual \
	>"$out/image-build.log" 2>&1

installer="$out/image/installer-serial.img"
[ -f "$installer" ] || fail "no installer image"
target="$out/target.img"
rm -f "$target"
qemu-img create -f raw "$target" "$disk_size" >/dev/null

vars="$(mktemp)"
cp "$OVMF_VARS" "$vars"

log "installing (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
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
	-nographic >"$out/install.log" 2>&1
set -e
rm -f "$vars"
grep -qF "OBKA_INSTALL_DONE" "$out/install.log" || fail "install did not complete"

# The installed image seeds the trigger on its first boot; every later boot
# advances the integration state machine.
efi_vars="$out/boot-vars.fd"
cp "$OVMF_VARS" "$efi_vars"
log_file="$out/integration.log"
: >"$log_file"

boot() {
	log "booting phase ${1} (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
	# A guest that fails mid-check does not power off, so QEMU hits the boot
	# timeout; tolerate that here and let the marker checks below report.
	obka_boot "$efi_vars" "$target" "$log_file" "$boot_timeout" || true
}

boot 1
boot 2
boot 3
boot 4

if grep -qF "OBKA_INTEGRATION_FAIL" "$log_file"; then
	fail "guest reported $(grep -m1 -F "OBKA_INTEGRATION_FAIL" "$log_file")"
fi
grep -qF "OBKA_HEALTH_REVERT" "$log_file" ||
	fail "health gate did not revert the failed update"
for marker in OBKA_INTEGRATION_PHASE1_PASS OBKA_INTEGRATION_PHASE2_PASS \
	OBKA_INTEGRATION_PHASE3_REACHED OBKA_INTEGRATION_PASS; do
	grep -qF "$marker" "$log_file" || fail "missing $marker; see $log_file"
done
printf 'PASS: install, update, failed update, and revert integration\n'
