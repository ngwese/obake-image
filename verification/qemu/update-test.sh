#!/usr/bin/env bash
set -euo pipefail

# Two-phase RAUC update verification. Builds a signed bundle from an update
# image, builds a verification image carrying the bundle (or a bundle signed by
# an untrusted CA for `broken`), boots it (slot A), installs the bundle, powers
# off, then boots again with the same EFI variables and asserts activation.
#
# Usage: update-test.sh [good|broken] [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

mode="${1:-good}"
arch="${2:-native}"
out="$project_root/dist/verify/$OBKA_ARCH/update-$mode"
bundle_version="${UPDATE_VERSION:-0.3.0}"
boot_timeout="${UPDATE_BOOT_TIMEOUT:-400}"
buildsh="$project_root/image/verification/build.sh"

log() { printf '[update-test] %s\n' "$*" >&2; }
fail() { printf '[update-test] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "building update image (version $bundle_version)"
bash "$project_root/image/os/scripts/make-signing-material.sh" "$out/trusted" >/dev/null
if [ "$mode" = "broken" ]; then
	bash "$project_root/image/os/scripts/make-signing-material.sh" "$out/untrusted" >/dev/null
	sign_cert="$out/untrusted/signing.cert.pem"
	sign_key="$out/untrusted/signing.key"
else
	sign_cert="$out/trusted/signing.cert.pem"
	sign_key="$out/trusted/signing.key"
fi

OBAKE_IMAGE_VERSION="$bundle_version" IMAGE_TAG="$bundle_version" MAKE_DISK=1 \
	VERIFY=1 VERIFY_UPDATE=1 \
	RAUC_SIGNING_CERT="$sign_cert" RAUC_SIGNING_KEY="$sign_key" \
	"$buildsh" "$arch" "$out/update" >"$out/update-build.log" 2>&1

bundle="$out/update/obake-$bundle_version-b.raucb"
[ -f "$bundle" ] || fail "no bundle built ($bundle)"

log "building verification image for mode $mode"
RAUC_KEYRING="$out/trusted/ca.cert.pem" VERIFY=1 VERIFY_UPDATE=1 \
	VERIFY_UPDATE_BUNDLE="$bundle" MAKE_DISK=1 \
	"$buildsh" "$arch" "$out/image" >"$out/build.log" 2>&1

disk="$out/image/disk-a.img"
[ -f "$disk" ] || fail "no verification disk"
efi_vars="$out/vars.fd"
cp "$OVMF_VARS" "$efi_vars"
log_file="$out/update.log"
: >"$log_file"

boot() {
	log "booting $1 (arch=$OBKA_ARCH accel=$OBKA_QEMU_ACCEL_NAME)"
	obka_boot "$efi_vars" "$disk" "$log_file" "$boot_timeout"
}
boot phase1
boot phase2

if [ "$mode" = "broken" ]; then
	grep -qF "OBKA_UPDATE_PHASE1_PASS" "$log_file" && fail "untrusted bundle was accepted"
	printf 'PASS: untrusted bundle rejected\n'
	exit 0
fi

grep -qF "OBKA_UPDATE_PHASE1_PASS" "$log_file" || fail "phase1 did not pass; see $log_file"
grep -qF "OBKA_UPDATE_PHASE2_PASS" "$log_file" || fail "phase2 did not pass; see $log_file"
printf 'PASS: update applied and activated\n'
