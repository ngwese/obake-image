#!/usr/bin/env bash
set -euo pipefail

# Health-gate verification. Builds a signed bundle, builds a verification image
# whose updated slot has a mock positive or negative health check, installs the
# bundle, and boots repeatedly with persistent EFI variables.
#
# Usage: health-test.sh [pass|revert] [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

mode="${1:-pass}"
arch="${2:-native}"
out="$project_root/dist/verify/$OBKA_ARCH/health-$mode"
bundle_version="${HEALTH_VERSION:-0.4.0}"
boot_timeout="${HEALTH_BOOT_TIMEOUT:-400}"
buildsh="$project_root/image/verification/build.sh"

log() { printf '[health-test] %s\n' "$*" >&2; }
fail() { printf '[health-test] FAIL: %s\n' "$*" >&2; exit 1; }

case "$mode" in
pass) mock_health=pass; max_attempts="${HEALTH_MAX_ATTEMPTS:-3}" ;;
revert) mock_health=fail; max_attempts="${HEALTH_MAX_ATTEMPTS:-1}" ;;
*) fail "unknown mode: $mode" ;;
esac

rm -rf "$out"
mkdir -p "$out"

log "building update image (version $bundle_version, mock_health=$mock_health)"
bash "$project_root/image/os/scripts/make-signing-material.sh" "$out/trusted" >/dev/null
OBAKE_IMAGE_VERSION="$bundle_version" IMAGE_TAG="$bundle_version" MAKE_DISK=1 \
	VERIFY=1 VERIFY_HEALTH=1 MOCK_HEALTH="$mock_health" HEALTH_MAX_ATTEMPTS="$max_attempts" \
	RAUC_SIGNING_CERT="$out/trusted/signing.cert.pem" \
	RAUC_SIGNING_KEY="$out/trusted/signing.key" \
	"$buildsh" "$arch" "$out/update" >"$out/update-build.log" 2>&1

bundle="$out/update/obake-$bundle_version-b.raucb"
[ -f "$bundle" ] || fail "no bundle built"

log "building verification image for mode $mode"
RAUC_KEYRING="$out/trusted/ca.cert.pem" VERIFY=1 VERIFY_HEALTH=1 \
	VERIFY_UPDATE_BUNDLE="$bundle" MAKE_DISK=1 \
	LOCAL_BUNDLE="/opt/obake/update.raucb" \
	MOCK_HEALTH="$mock_health" HEALTH_MAX_ATTEMPTS="$max_attempts" \
	"$buildsh" "$arch" "$out/image" >"$out/build.log" 2>&1

disk="$out/image/disk-a.img"
[ -f "$disk" ] || fail "no verification disk"
efi_vars="$out/vars.fd"
cp "$OVMF_VARS" "$efi_vars"
log_file="$out/health.log"
: >"$log_file"

boot() {
	log "booting $1 (arch=$OBKA_ARCH accel=$OBKA_QEMU_ACCEL_NAME)"
	obka_boot "$efi_vars" "$disk" "$log_file" "$boot_timeout"
}

boot 1
boot 2
[ "$mode" = "revert" ] && boot 3

grep -qF "OBKA_HEALTH_PHASE1_PASS" "$log_file" ||
	fail "update client did not snapshot/mark pending"

if [ "$mode" = "pass" ]; then
	grep -qF "OBKA_HEALTH_PASS" "$log_file" || fail "healthy slot was not marked good"
	printf 'PASS: healthy update marked good\n'
	exit 0
fi

grep -qF "OBKA_HEALTH_REVERT" "$log_file" || fail "unhealthy update was not reverted"
grep -qF "OBKA_HEALTH_TEST_BOOT booted=rootfs.0" "$log_file" ||
	fail "did not fall back to the previous slot"
grep -qF "OBKA_HEALTH_CONFIG_RESTORED" "$log_file" ||
	fail "previous configuration was not restored"
printf 'PASS: unhealthy update reverted and configuration restored\n'
