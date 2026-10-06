#!/usr/bin/env bash
set -euo pipefail

# Build a good image and one image per deliberately broken behavior, boot each
# under QEMU, and assert the matching functional check reports failure. Run
# inside the build environment.
#
# Usage: verify-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../.." && pwd)"
arch="${1:-amd64}"
out_base="${OUT_BASE:-$project_root/dist/verify/$arch}"
timeout_s="${VERIFY_BOOT_TIMEOUT:-300}"

cases="good ro etc var user"
declare -A expect=(
  [good]="OBKA_VERIFY_PASS"
  [ro]="OBKA_CHECK root-readonly=fail"
  [etc]="OBKA_CHECK etc-overlay=fail"
  [var]="OBKA_CHECK var-contract=fail"
  [user]="OBKA_CHECK user-partition=fail"
)

for case in $cases; do
  log() { printf '[verify] %s\n' "$*" >&2; }
  log "case $case (expect: ${expect[$case]})"
  mkdir -p "$out_base/$case"

  if [ "$case" = "good" ]; then break_env=""; else break_env="$case"; fi
  VERIFY=1 MAKE_DISK=1 BREAK="$break_env" ARCH="$arch" OUT="$out_base/$case" \
    "$project_root/os/build.sh" >"$out_base/$case/build.log" 2>&1

  if BOOT_TIMEOUT="$timeout_s" BOOT_MARKER="${expect[$case]}" \
    BOOT_LOG="$out_base/$case/boot.log" \
    "$here/boot-test.sh" "$out_base/$case/disk-a.img"; then
    log "PASS $case"
  else
    log "FAIL $case: expected '${expect[$case]}' in $out_base/$case/boot.log"
    exit 1
  fi
done

printf 'OBKA_VERIFY_SUITE_PASS\n'
