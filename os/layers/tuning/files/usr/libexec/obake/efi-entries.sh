#!/bin/sh
# Ensure the per-slot EFI boot entries exist and point at the slot UKIs on the
# ESP. RAUC's efi backend matches slots by the EFI boot entry description, which
# must equal the slot's bootname (A/B). The kernel must expose EFI runtime
# services (the cmdline sets efi=runtime) for efivarfs to be mountable.
set -u

[ -d /sys/firmware/efi ] || exit 0

if ! mountpoint -q /sys/firmware/efi/efivars; then
	modprobe efivarfs 2>/dev/null || true
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
fi
mountpoint -q /sys/firmware/efi/efivars || exit 0

esp="$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)"
[ -n "$esp" ] || exit 0

disk="$(lsblk -no PKNAME "$esp" 2>/dev/null | head -1)"
part="$(lsblk -no PARTN "$esp" 2>/dev/null | head -1)"
[ -n "$disk" ] && [ -n "$part" ] || exit 0
disk="/dev/$disk"

created=0
ensure_entry() {
	label="$1"
	loader="$2"
	if efibootmgr 2>/dev/null | grep -qE "Boot[0-9A-Fa-f]{4}\*? ${label}$"; then
		return 0
	fi
	if efibootmgr -q -c -d "$disk" -p "$part" -L "$label" -l "$loader" 2>/dev/null; then
		created=1
	fi
}

ensure_entry A '\EFI\Linux\obake-a.efi'
ensure_entry B '\EFI\Linux\obake-b.efi'

# On first creation, prefer slot A. RAUC owns the boot order after this, so only
# set it when we actually created the entries (otherwise we would override the
# activation RAUC performed for an update).
if [ "$created" = 1 ]; then
	num() { efibootmgr 2>/dev/null | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} $1\$/\1/p" | head -1; }
	a="$(num A)"
	b="$(num B)"
	if [ -n "$a" ] && [ -n "$b" ]; then
		efibootmgr -q -o "$a,$b" 2>/dev/null || true
	fi
fi

exit 0
