#!/usr/bin/env bash
# Headless check of image/os/scripts/efi-boot-entries.sh against a stub
# efibootmgr. Fails if a stale, VenHw, inactive, or duplicate A/B entry
# remains, if an unrelated entry is deleted, or if the preferred slot is
# not first when BootNext is unset.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/../os/scripts/efi-boot-entries.sh"
partuuid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
old_guid="11111111-2222-3333-4444-555555555555"

fail() {
	printf 'efi-boot-entries-test: %s\n' "$*" >&2
	exit 1
}

[ -x "$helper" ] || fail "helper missing: $helper"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
state="$tmp/state"
log="$tmp/log"

cat >"$tmp/bin/efibootmgr" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$EFIBOOT_LOG"
delete=0
create=0
num=""
label=""
loader=""
order=""
while [ $# -gt 0 ]; do
	case "$1" in
	-q | -v) shift ;;
	-B) delete=1; shift ;;
	-c) create=1; shift ;;
	-b | -L | -l | -d | -p | -o)
		key="$1"
		val="${2:-}"
		shift 2
		case "$key" in
		-b) num="$val" ;;
		-L) label="$val" ;;
		-l) loader="$val" ;;
		-o) order="$val" ;;
		esac
		;;
	*) shift ;;
	esac
done
num="$(printf '%s' "$num" | tr '[:lower:]' '[:upper:]')"
if [ "$delete" = 1 ]; then
	[ -n "$num" ]
	tmp="$(mktemp)"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		BootOrder:*)
			rest="${line#BootOrder:}"
			rest="${rest//[[:space:]]/}"
			out=""
			IFS=',' read -r -a items <<<"$rest"
			for item in "${items[@]+"${items[@]}"}"; do
				item="$(printf '%s' "$item" | tr '[:lower:]' '[:upper:]')"
				[ "$item" = "$num" ] && continue
				out="${out:+$out,}$item"
			done
			printf 'BootOrder: %s\n' "$out"
			;;
		"Boot${num}"*) ;;
		*) printf '%s\n' "$line" ;;
		esac
	done <"$EFIBOOT_STATE" >"$tmp"
	mv "$tmp" "$EFIBOOT_STATE"
	exit 0
fi
if [ "$create" = 1 ]; then
	[ -n "$label" ] && [ -n "$loader" ]
	max=0
	while IFS= read -r line; do
		case "$line" in
		Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*)
			hex="$(printf '%s' "${line:4:4}" | tr '[:lower:]' '[:upper:]')"
			val=$((16#$hex))
			[ "$val" -gt "$max" ] && max="$val"
			;;
		esac
	done <"$EFIBOOT_STATE"
	printf -v next '%04X' $((max + 1))
	printf 'Boot%s* %s HD(1,GPT,%s,0x800,0x100)/%s\n' \
		"$next" "$label" "$EFIBOOT_PARTUUID" "$loader" >>"$EFIBOOT_STATE"
	exit 0
fi
if [ -n "$order" ]; then
	tmp="$(mktemp)"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		BootOrder:*) printf 'BootOrder: %s\n' "$order" ;;
		*) printf '%s\n' "$line" ;;
		esac
	done <"$EFIBOOT_STATE" >"$tmp"
	mv "$tmp" "$EFIBOOT_STATE"
	exit 0
fi
cat "$EFIBOOT_STATE"
STUB
chmod 0755 "$tmp/bin/efibootmgr"

write_fixture() {
	local bootnext="${1:-}"
	{
		printf 'BootCurrent: 0004\n'
		if [ -n "$bootnext" ]; then
			printf 'BootNext: %s\n' "$bootnext"
		fi
		cat <<EOF
BootOrder: 0001,0002,0006,0003,0004,0005
Boot0001* A HD(1,GPT,${old_guid},0x800,0x100)/\\EFI\\Linux\\obake-a.efi
Boot0002* B VenHw(99e275e7-75a0-4b37-a2e6-c5385e6c00cb)
Boot0006  A HD(1,GPT,${partuuid},0x800,0x100)/\\EFI\\Linux\\obake-a.efi
Boot0003* A HD(1,GPT,${partuuid},0x800,0x100)/\\EFI\\Linux\\obake-a.efi
Boot0004* B HD(1,GPT,${partuuid},0x800,0x100)/\\EFI\\Linux\\obake-b.efi
Boot0005* UEFI OS HD(1,GPT,${partuuid},0x800,0x100)/\\EFI\\BOOT\\BOOTX64.EFI
EOF
	} >"$state"
	: >"$log"
}

export EFIBOOT_LOG="$log"
export EFIBOOT_STATE="$state"
export EFIBOOT_PARTUUID="$partuuid"
export PATH="$tmp/bin:$PATH"

count_label() {
	local label="$1" n=0 line rest first
	while IFS= read -r line; do
		case "$line" in
		Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*)
			if [ "${line:8:1}" = "*" ]; then
				rest="${line:9}"
			else
				rest="${line:8}"
			fi
			rest="${rest#"${rest%%[![:space:]]*}"}"
			first="${rest%%[[:space:]]*}"
			[ "$first" = "$label" ] && n=$((n + 1))
			;;
		esac
	done <"$state"
	printf '%s' "$n"
}

assert_clean_pair() {
	grep -q -- "-b 0001 -B" "$log" || fail "stale A on $old_guid was not deleted"
	grep -q -- "-b 0002 -B" "$log" || fail "VenHw B was not deleted"
	grep -q -- "-b 0006 -B" "$log" || fail "inactive duplicate A was not deleted"
	grep -q -- "-b 0005" "$log" && fail "unrelated UEFI OS entry was deleted"
	grep -q 'UEFI OS' "$state" || fail "unrelated UEFI OS entry is gone"
	grep -q "$old_guid" "$state" && fail "stale A entry remains"
	grep -q 'VenHw' "$state" && fail "VenHw B entry remains"
	[ "$(count_label A)" = 1 ] || fail "expected one A entry, got $(count_label A)"
	[ "$(count_label B)" = 1 ] || fail "expected one B entry, got $(count_label B)"
	grep -q "Boot0003\\* A" "$state" || fail "current ESP A was not kept"
	grep -q "Boot0004\\* B" "$state" || fail "current ESP B was not kept"
}

write_fixture
out="$("$helper" --disk /dev/vda --part 1 --partuuid "$partuuid" --prefer a)"
assert_clean_pair
grep -q -- "-o 0003,0004,0005" "$log" || fail "preferred slot A is not first in BootOrder"
[ "$out" = "order 0003,0004,0005" ] || fail "stdout order was '$out'"

# Re-run on the already-reconciled listing must not invent another pair.
: >"$log"
out="$("$helper" --disk /dev/vda --part 1 --partuuid "$partuuid" --prefer b)"
grep -q -- "-B" "$log" && fail "second reconcile deleted an entry"
grep -q -- "-o 0004,0003,0005" "$log" || fail "preferred slot B is not first in BootOrder"
[ "$out" = "order 0004,0003,0005" ] || fail "stdout order was '$out'"
[ "$(count_label A)" = 1 ] || fail "second reconcile changed the A count"
[ "$(count_label B)" = 1 ] || fail "second reconcile changed the B count"
grep -q 'UEFI OS' "$state" || fail "second reconcile dropped UEFI OS"

write_fixture 0001
out="$("$helper" --disk /dev/vda --part 1 --partuuid "$partuuid" --prefer a)"
assert_clean_pair
[ "$out" = "order unchanged" ] || fail "BootNext run printed '$out'"
grep -q -- "-o " "$log" && fail "BootOrder changed while BootNext was set"

write_fixture 0001
out="$("$helper" --disk /dev/vda --part 1 --partuuid "$partuuid" --prefer a --force-order)"
assert_clean_pair
[ "$out" = "order 0003,0004,0005" ] || fail "force-order stdout was '$out'"
grep -q -- "-o 0003,0004,0005" "$log" || fail "installer force-order did not set BootOrder"

# No current-ESP pair: create both, keep UEFI OS, prefer A.
cat >"$state" <<EOF
BootCurrent: 0005
BootOrder: 0005
Boot0005* UEFI OS HD(1,GPT,${partuuid},0x800,0x100)/\\EFI\\BOOT\\BOOTX64.EFI
EOF
: >"$log"
out="$("$helper" --disk /dev/vda --part 1 --partuuid "$partuuid" --prefer a)"
grep -q -- "-c -d /dev/vda -p 1 -L A -l" "$log" || fail "missing A was not created"
grep -q -- "-c -d /dev/vda -p 1 -L B -l" "$log" || fail "missing B was not created"
grep -q 'UEFI OS' "$state" || fail "create path dropped UEFI OS"
[ "$(count_label A)" = 1 ] || fail "create path did not leave one A"
[ "$(count_label B)" = 1 ] || fail "create path did not leave one B"
[ "$out" = "order 0006,0007,0005" ] || fail "create stdout was '$out'"
order_line="$(grep -- '-o ' "$log" | head -1)"
case "$order_line" in
*"-o 0006,0007,0005") ;;
*) fail "created pair was not ordered preferred-slot first: $order_line" ;;
esac

printf 'efi-boot-entries-test: pass\n'
