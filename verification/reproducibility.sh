#!/usr/bin/env bash
set -euo pipefail

# Reproducibility check for a board.
#
# Builds the board twice with the same output directory (clean between) and the
# frozen download cache, then compares the artifacts that must be identical when
# the pins do not change:
#
#   - root-a.tar (the canonical rootfs archive)
#   - pinned-inputs.json (the selected Buildroot/kernel/runtime versions)
#
# The record is written to image/verification/reproducibility/<board>.sha256.
# On macOS the builds run in the native build container; on a Linux host they
# run directly.
#
# Usage: reproducibility.sh [board]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../.." && pwd)"
board="${1:-generic-aarch64}"

# Re-exec inside the build container when Docker is available. Inside the
# container there is no Docker, so this does not recurse.
if command -v docker >/dev/null 2>&1 && [ -x "$here/build-env/run.sh" ]; then
	exec "$here/build-env/run.sh" bash image/verification/reproducibility.sh "$board"
fi

work="${OBAKE_WORK:-$project_root/image/.build/buildroot}"
dl="${DL_DIR:-$work/dl}"
out="${OBAKE_OUT:-$work/output/$board-repro}"
buildsh="$project_root/image/os/buildroot/build.sh"
record_dir="$here/reproducibility"

log() { printf '[reproducibility] %s\n' "$*" >&2; }
fail() { printf '[reproducibility] FAIL: %s\n' "$*" >&2; exit 1; }

# One clean-and-build cycle in a fixed output directory (Buildroot's
# reproducibility guarantee is scoped to a fixed O= path).
cycle() {
	OBAKE_WORK="$work" DL_DIR="$dl" OBAKE_OUT="$out" MAKE_DISK=0 \
		bash "$buildsh" "$board" clean >/dev/null
	OBAKE_WORK="$work" DL_DIR="$dl" OBAKE_OUT="$out" MAKE_DISK=0 \
		bash "$buildsh" "$board" >/dev/null
}

digest() { sha256sum "$1" | cut -d' ' -f1; }

rm -rf "$out"
mkdir -p "$out" "$record_dir"

log "build 1/2 ($board)"
cycle
[ -f "$out/images/root-a.tar" ] || fail "no root-a.tar after build 1"
r1="$(digest "$out/images/root-a.tar")"
p1="$(digest "$out/images/pinned-inputs.json")"

log "build 2/2 ($board)"
cycle
r2="$(digest "$out/images/root-a.tar")"
p2="$(digest "$out/images/pinned-inputs.json")"

[ "$p1" = "$p2" ] || fail "pinned inputs differ between builds ($p1 != $p2)"
[ "$r1" = "$r2" ] || fail "root-a.tar is not reproducible ($r1 != $r2)"

record="$record_dir/$board.sha256"
cp "$out/images/pinned-inputs.json" "$record_dir/$board.pinned-inputs.json"
{
	printf '# board: %s\n' "$board"
	printf '# pinned inputs: %s.pinned-inputs.json\n' "$board"
	printf '%s  %s\n' "$r1" root-a.tar
	printf '%s  %s\n' "$p1" pinned-inputs.json
} >"$record"

cat "$record"
printf 'OBKA_REPRODUCIBLE_PASS\n'
