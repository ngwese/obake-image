#!/usr/bin/env bash
#
# Enforce the board/base split from the os-image-build spec: every board image
# derives from one shared Buildroot base and differs only in its board fragment
# and overlay.
#
# build.sh forms each board's defconfig as configs/obake_base.config followed by
# configs/obake-<board>.config. This script checks that no board fragment
# redefines a symbol set by the base (which would mean the base is no longer
# shared) and prints, for each pair of boards, the symbols that differ. Almost
# all of the difference must be the board's arch, kernel config selection, board
# overlay, and (for rk35xx) its bootloader; the check fails if a board touches a
# base symbol.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
configs="$here/configs"
base="$configs/obake_base.config"

syms() { sed -n 's/^\(BR2_[A-Za-z0-9_]*\)=.*/\1/p' "$1" | sort -u; }

boards=()
for f in "$configs"/obake-*.config; do
	b="$(basename "$f" .config)"
	boards+=("${b#obake-}")
done

base_syms="$(syms "$base")"
status=0
for b in "${boards[@]}"; do
	frag="$configs/obake-$b.config"
	overlap="$(comm -12 <(printf '%s\n' "$base_syms") <(syms "$frag"))"
	if [ -n "$overlap" ]; then
		printf 'FAIL: board %s redefines base symbols:\n%s\n' "$b" "$overlap" >&2
		status=1
	fi
done

for ((i = 0; i < ${#boards[@]}; i++)); do
	for ((j = i + 1; j < ${#boards[@]}; j++)); do
		a="${boards[$i]}"
		b="${boards[$j]}"
		# A and B differ only where their fragments differ (same base).
		delta="$(comm -3 <(cat "$base" "$configs/obake-$a.config" | sort -u) \
			<(cat "$base" "$configs/obake-$b.config" | sort -u))"
		printf '%s vs %s differ in %s symbol(s)\n' "$a" "$b" \
			"$(printf '%s\n' "$delta" | grep -c . || true)"
	done
done

[ "$status" -eq 0 ] && printf 'OBKA_BOARD_BASE_PASS\n'
exit "$status"
