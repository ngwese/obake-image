#!/usr/bin/env bash
# Reconcile the firmware boot entries for the obake A/B slots.
#
# Keep an entry only when all of these hold:
#   - the label is exactly A or B
#   - efibootmgr shows it active (BootNNNN*)
#   - the path is \EFI\Linux\obake-a.efi or obake-b.efi for that label
#   - the partition GUID is the ESP being installed or mounted
# If several entries match a label, keep the one earliest in BootOrder.
# Delete every other A or B, including VenHw entries, entries for another
# disk, and entries that are not active. Labels other than A and B are left
# in place.
#
# When BootNext is set, leave BootOrder unchanged (do not clear BootNext).
# Otherwise set BootOrder to the preferred slot, then the other slot, then
# the remaining non-slot entries in their previous order.
# --force-order sets that order even when BootNext is set (the installer).
set -euo pipefail

disk=""
part=""
prefer=""
partuuid=""
force_order=0

usage() {
	printf 'usage: %s --disk DEV --part N --prefer a|b [--partuuid GUID] [--force-order]\n' \
		"$0" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--disk) disk="${2:-}"; shift 2 ;;
	--part) part="${2:-}"; shift 2 ;;
	--prefer) prefer="${2:-}"; shift 2 ;;
	--partuuid) partuuid="${2:-}"; shift 2 ;;
	--force-order) force_order=1; shift ;;
	-h | --help) usage ;;
	*) usage ;;
	esac
done

[ -n "$disk" ] && [ -n "$part" ] || usage
case "$prefer" in
a | b) ;;
*) usage ;;
esac

if [ -z "$partuuid" ]; then
	base="$(basename "$disk")"
	esp_dev=""
	for node in /sys/class/block/"$base"*; do
		[ -f "$node/partition" ] || continue
		if [ "$(cat "$node/partition")" = "$part" ]; then
			esp_dev="/dev/$(basename "$node")"
			break
		fi
	done
	[ -n "$esp_dev" ] || {
		printf '[efi-boot] ESP partition %s on %s not found\n' "$part" "$disk" >&2
		exit 1
	}
	partuuid="$(lsblk -no PARTUUID "$esp_dev" | head -1)"
fi
[ -n "$partuuid" ] || {
	printf '[efi-boot] ESP partition UUID is empty\n' >&2
	exit 1
}

listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT

refresh() {
	efibootmgr -v >"$listing"
}

entry_num=()
entry_star=()
entry_label=()
entry_line=()
bootnext=""
bootorder=""

parse_listing() {
	entry_num=()
	entry_star=()
	entry_label=()
	entry_line=()
	bootnext=""
	bootorder=""
	local line num star rest label
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		BootNext:*)
			bootnext="${line#BootNext:}"
			bootnext="${bootnext#"${bootnext%%[![:space:]]*}"}"
			bootnext="${bootnext%%[[:space:]]*}"
			;;
		BootOrder:*)
			bootorder="${line#BootOrder:}"
			bootorder="${bootorder//[[:space:]]/}"
			;;
		Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*)
			num="$(printf '%s' "${line:4:4}" | tr '[:lower:]' '[:upper:]')"
			if [ "${line:8:1}" = "*" ]; then
				star=1
				rest="${line:9}"
			else
				star=0
				rest="${line:8}"
			fi
			rest="${rest#"${rest%%[![:space:]]*}"}"
			label="${rest%%[[:space:]]*}"
			entry_num+=("$num")
			entry_star+=("$star")
			entry_label+=("$label")
			entry_line+=("$line")
			;;
		esac
	done <"$listing"
}

path_ok() {
	local label="$1" line="$2" want
	case "$label" in
	A) want='efi[/\\]linux[/\\]obake-a\.efi' ;;
	B) want='efi[/\\]linux[/\\]obake-b\.efi' ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$line" | grep -Eiq "$want"
}

guid_ok() {
	printf '%s\n' "$1" | grep -Fiq "$partuuid"
}

order_index() {
	local want="$1" idx=0 item
	IFS=',' read -r -a _order <<<"$bootorder"
	for item in "${_order[@]}"; do
		item="$(printf '%s' "$item" | tr '[:lower:]' '[:upper:]')"
		if [ "$item" = "$want" ]; then
			printf '%s' "$idx"
			return 0
		fi
		idx=$((idx + 1))
	done
	printf '100000'
}

pick_kept() {
	local want="$1" i best best_idx idx
	best=""
	best_idx=100001
	for i in "${!entry_num[@]}"; do
		[ "${entry_label[$i]}" = "$want" ] || continue
		[ "${entry_star[$i]}" = 1 ] || continue
		path_ok "$want" "${entry_line[$i]}" || continue
		guid_ok "${entry_line[$i]}" || continue
		idx="$(order_index "${entry_num[$i]}")"
		if [ "$idx" -lt "$best_idx" ]; then
			best="${entry_num[$i]}"
			best_idx="$idx"
		fi
	done
	printf '%s' "$best"
}

slot_label() {
	local want="$1" i
	for i in "${!entry_num[@]}"; do
		if [ "${entry_num[$i]}" = "$want" ]; then
			printf '%s' "${entry_label[$i]}"
			return 0
		fi
	done
	return 1
}

create_slot() {
	local label="$1" loader
	case "$label" in
	A) loader='\EFI\Linux\obake-a.efi' ;;
	B) loader='\EFI\Linux\obake-b.efi' ;;
	esac
	efibootmgr -q -c -d "$disk" -p "$part" -L "$label" -l "$loader"
}

refresh
parse_listing
original_order="$bootorder"
seen_bootnext="$bootnext"

keep_a="$(pick_kept A)"
keep_b="$(pick_kept B)"

deleted=()
for i in "${!entry_num[@]}"; do
	case "${entry_label[$i]}" in
	A | B) ;;
	*) continue ;;
	esac
	num="${entry_num[$i]}"
	if [ "$num" = "$keep_a" ] || [ "$num" = "$keep_b" ]; then
		continue
	fi
	deleted+=("$num")
done

for num in "${deleted[@]+"${deleted[@]}"}"; do
	efibootmgr -q -b "$num" -B
done

if [ -z "$keep_a" ]; then
	create_slot A
fi
if [ -z "$keep_b" ]; then
	create_slot B
fi

refresh
parse_listing
keep_a="$(pick_kept A)"
keep_b="$(pick_kept B)"
[ -n "$keep_a" ] && [ -n "$keep_b" ] || {
	printf '[efi-boot] missing slot entry after reconcile (A=%s B=%s)\n' \
		"$keep_a" "$keep_b" >&2
	exit 1
}

if [ "$force_order" != 1 ] && [ -n "$seen_bootnext" ]; then
	printf 'order unchanged\n'
	exit 0
fi

if [ "$prefer" = a ]; then
	result="$keep_a,$keep_b"
else
	result="$keep_b,$keep_a"
fi

IFS=',' read -r -a prev <<<"$original_order"
for num in "${prev[@]+"${prev[@]}"}"; do
	[ -n "$num" ] || continue
	num="$(printf '%s' "$num" | tr '[:lower:]' '[:upper:]')"
	[ "$num" = "$keep_a" ] && continue
	[ "$num" = "$keep_b" ] && continue
	label="$(slot_label "$num" || true)"
	case "$label" in
	A | B) continue ;;
	esac
	# Drop numbers that are no longer in the listing (deleted slots).
	slot_label "$num" >/dev/null || continue
	result="$result,$num"
done

efibootmgr -q -o "$result"
printf 'order %s\n' "$result"
