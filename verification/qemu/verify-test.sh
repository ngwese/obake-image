#!/usr/bin/env bash
set -euo pipefail

# Build a good image and one image per deliberately broken behavior, boot each
# under QEMU, and assert the matching functional check reports failure.
#
# Usage: verify-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

arch="${1:-native}"
out_base="${OUT_BASE:-$project_root/dist/verify/$OBKA_ARCH/verify}"
timeout_s="${VERIFY_BOOT_TIMEOUT:-300}"

expect_for() {
	case "$1" in
	good) printf 'OBKA_VERIFY_PASS' ;;
	ro) printf 'OBKA_CHECK root-readonly=fail' ;;
	etc) printf 'OBKA_CHECK etc-overlay=fail' ;;
	var) printf 'OBKA_CHECK var-contract=fail' ;;
	user) printf 'OBKA_CHECK user-partition=fail' ;;
	esac
}

for case in good ro etc var user; do
	expect="$(expect_for "$case")"
	log() { printf '[verify] %s\n' "$*" >&2; }
	log "case $case (expect: $expect)"
	d="$out_base/$case"
	rm -rf "$d"
	mkdir -p "$d"

	break_env=""
	[ "$case" = "good" ] || break_env="$case"
	VERIFY=1 BREAK="$break_env" "$project_root/image/verification/build.sh" "$arch" "$d" \
		>"$d/build.log" 2>&1

	if BOOT_TIMEOUT="$timeout_s" BOOT_MARKER="$expect" BOOT_LOG="$d/boot.log" \
		"$here/boot-test.sh" "$d/disk-a.img"; then
		log "PASS $case"
	else
		log "FAIL $case: expected '$expect' in $d/boot.log"
		exit 1
	fi
done

printf 'OBKA_VERIFY_SUITE_PASS\n'
