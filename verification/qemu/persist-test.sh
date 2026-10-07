#!/usr/bin/env bash
set -euo pipefail

# Writable-contract persistence verification. Builds a verification disk,
# writes markers in one boot, reboots to confirm /etc and the persisted /var
# subset survive and transient /var is discarded, then switches slots and
# confirms they are retained.
#
# Usage: persist-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

arch="${1:-native}"
out="${OUT_BASE:-$project_root/dist/verify/$OBKA_ARCH/persist}"
boot_timeout="${PERSIST_BOOT_TIMEOUT:-300}"

log() { printf '[persist-test] %s\n' "$*" >&2; }
fail() { printf '[persist-test] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "building verification image"
artifacts="$(VERIFY=1 VERIFY_PERSIST=1 OBKA_REBUILD=1 obka_build "$arch")"

disk="$artifacts/disk-a.img"
[ -f "$disk" ] || fail "no disk image in $artifacts"
efi_vars="$out/vars.fd"
cp "$OVMF_VARS" "$efi_vars"
log_file="$out/persist.log"
: >"$log_file"

boot() {
	log "booting $1 (arch=$OBKA_ARCH accel=$OBKA_QEMU_ACCEL_NAME)"
	obka_boot "$efi_vars" "$disk" "$log_file" "$boot_timeout"
}

boot 1
boot 2
boot 3

for phase in PHASE1 PHASE2 PHASE3; do
	grep -qF "OBKA_PERSIST_${phase}_PASS" "$log_file" ||
		fail "$phase did not pass; see $log_file"
done
printf 'PASS: writable contract persists across reboot and slot switch\n'
