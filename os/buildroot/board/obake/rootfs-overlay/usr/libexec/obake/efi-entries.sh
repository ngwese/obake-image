#!/bin/sh
# Reconcile one active EFI boot entry per slot before RAUC starts. RAUC's efi
# backend matches bootname A/B by description, so a stale or duplicate entry
# would activate the wrong number. This does not return early just because
# some A or B label already exists. When BootNext is set, the helper leaves
# BootOrder unchanged and does not clear BootNext.
set -u

[ -d /sys/firmware/efi ] || exit 0

if ! mountpoint -q /sys/firmware/efi/efivars; then
	modprobe efivarfs 2>/dev/null || true
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
fi
mountpoint -q /sys/firmware/efi/efivars || exit 0

esp="$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)"
[ -n "$esp" ] || exit 0

disk="$(lsblk -nro PKNAME "$esp" 2>/dev/null | head -1)"
part="$(lsblk -nro PARTN "$esp" 2>/dev/null | head -1)"
[ -n "$disk" ] && [ -n "$part" ] || exit 0
disk="/dev/$disk"

prefer=a
case "$(cat /proc/cmdline 2>/dev/null || true)" in
*root=PARTLABEL=OBKA_ROOT_B*) prefer=b ;;
esac

helper=/usr/libexec/obake/efi-boot-entries.sh
[ -x "$helper" ] || exit 1
exec "$helper" --disk "$disk" --part "$part" --prefer "$prefer"
