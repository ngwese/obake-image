#!/usr/bin/env bash
set -euo pipefail

# End-to-end integration verification on x86_64:
#   install (installer) -> customize -> update -> reboot -> forced failed
#   update -> revert, asserting the writable contract and that the user
#   partition is never modified by the update/revert.
#
# Build and verification are decoupled: each image is built with the
# verification build wrapper (which uses the Buildroot build container when
# Docker is available) and the resulting artifacts are booted under the host's
# QEMU. The RAUC bundles are assembled from the built artifacts with
# `make-bundle.sh`, so `rauc` must be on PATH (the verify-env container
# provides it).
#
# Usage: integration-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

arch="${1:-native}"
out="${OUT_BASE:-$project_root/dist/verify/$OBKA_ARCH/integration}"
timeout_s="${INSTALL_TIMEOUT:-900}"
boot_timeout="${INTEGRATION_BOOT_TIMEOUT:-400}"
buildsh="$project_root/image/verification/build.sh"
scripts="$project_root/image/os/scripts"

base_version="${INTEGRATION_BASE_VERSION:-0.0.0}"
good_version="${INTEGRATION_GOOD_VERSION:-0.5.0}"
bad_version="${INTEGRATION_BAD_VERSION:-0.6.0}"
disk_size="${INTEGRATION_DISK_SIZE:-8G}"

log() { printf '[integration] %s\n' "$*" >&2; }
fail() { printf '[integration] FAIL: %s\n' "$*" >&2; exit 1; }

command -v rauc >/dev/null 2>&1 ||
	fail "rauc is required to assemble the update bundles (use verify-env/run.sh)"

rm -rf "$out"
mkdir -p "$out"

log "generating signing material"
bash "$scripts/make-signing-material.sh" "$out/trusted" >/dev/null
keyring="$out/trusted/ca.cert.pem"
sign_cert="$out/trusted/signing.cert.pem"
sign_key="$out/trusted/signing.key"

bundle() { # bundle <artifacts> <slot> <version> <out.raucb>
	RAUC_SIGNING_CERT="$sign_cert" RAUC_SIGNING_KEY="$sign_key" \
		bash "$scripts/make-bundle.sh" "$2" "$3" \
		"$1/root-$2.img" "$1/obake-$2.efi" "$(dirname "$4")" >/dev/null
	mv "$(dirname "$4")/obake-$3-$2.raucb" "$4"
}

log "building bad update artifacts (mock_health=fail, version $bad_version)"
OBAKE_IMAGE_VERSION="$bad_version" IMAGE_TAG="$bad_version" MAKE_DISK=0 \
	VERIFY=1 VERIFY_INTEGRATION=1 \
	MOCK_HEALTH=fail HEALTH_MAX_ATTEMPTS=1 \
	bash "$buildsh" "$arch" "$out/bad" >"$out/bad-build.log" 2>&1
# The bad update targets slot A (the inactive slot while running the good slot).
bundle "$out/bad" a "$bad_version" "$out/bad.raucb"

log "building good update artifacts (mock_health=pass, version $good_version)"
OBAKE_IMAGE_VERSION="$good_version" IMAGE_TAG="$good_version" MAKE_DISK=0 \
	VERIFY=1 VERIFY_INTEGRATION=1 \
	MOCK_HEALTH=pass HEALTH_MAX_ATTEMPTS=3 \
	VERIFY_INTEGRATION_BAD="$out/bad.raucb" \
	RAUC_KEYRING="$keyring" \
	bash "$buildsh" "$arch" "$out/good" >"$out/good-build.log" 2>&1
# The good update targets slot B (the inactive slot while running slot A).
bundle "$out/good" b "$good_version" "$out/good.raucb"

log "building installed image and installer (base version $base_version)"
OBAKE_IMAGE_VERSION="$base_version" IMAGE_TAG="$base_version" \
	MOCK_HEALTH=pass HEALTH_MAX_ATTEMPTS=3 \
	VERIFY=1 VERIFY_INTEGRATION=1 \
	VERIFY_INTEGRATION_GOOD="$out/good.raucb" \
	RAUC_KEYRING="$keyring" \
	MAKE_INSTALLER=1 \
	bash "$buildsh" "$arch" "$out/image" >"$out/image-build.log" 2>&1

installer="$out/image/installer.img"
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