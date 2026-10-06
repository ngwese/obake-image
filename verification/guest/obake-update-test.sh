#!/bin/sh
# Two-phase RAUC update functional test for the verification image.
#
# Phase 1 (running slot A): install a signed bundle for slot B, assert the
# active slot rootfs is untouched, the inactive slot rootfs is written, and the
# update is activated, then power off.
#
# Phase 2 (running the newly installed slot B): assert the firmware booted the
# updated slot and that its rootfs carries the update image tag.
#
# Both the base image and the update image install this service, so phase 2 can
# run from the freshly installed slot.
set -u

bundle="/opt/obake/update.raucb"
marker="/persist/obake-update-phase1"

fail() {
	printf 'OBKA_UPDATE_FAIL %s\n' "$1"
	[ -f /tmp/update.log ] && cat /tmp/update.log >/dev/console 2>/dev/null
	exit 1
}
finish() {
	sync
	/usr/bin/systemctl poweroff -f
	exit 0
}
booted_slot() { rauc status 2>/dev/null | sed -n 's/^Booted from: \(rootfs\.[01]\).*/\1/p'; }
primary_slot() { rauc status 2>/dev/null | sed -n 's/^Activated: \(rootfs\.[01]\).*/\1/p'; }

# mount_tag <A|B> <present|absent>
mount_tag() {
	slot="$1"
	expect="$2"
	mnt="/run/obka-$slot"
	mkdir -p "$mnt"
	mount -o ro "/dev/disk/by-partlabel/OBKA_ROOT_$slot" "$mnt" || return 1
	if [ "$expect" = "present" ]; then
		[ -s "$mnt/etc/obake/image-tag" ]
	else
		! [ -s "$mnt/etc/obake/image-tag" ]
	fi
	rc=$?
	umount "$mnt"
	return $rc
}

# Phase 2: the update must be active after reboot.
if [ -f "$marker" ]; then
	[ "$(booted_slot)" = "rootfs.1" ] || fail "phase2 not booted from slot B"
	[ "$(primary_slot)" = "rootfs.1" ] || fail "phase2 primary not rootfs.1"
	[ -s /etc/obake/image-tag ] || fail "phase2 update tag missing"
	[ "$(cat /home/obake-update-user-marker 2>/dev/null)" = user ] ||
		fail "phase2 user data changed by update"
	printf 'OBKA_UPDATE_VERSION=%s\n' "$(cat /etc/obake/image-version 2>/dev/null)"
	printf 'OBKA_UPDATE_KERNEL=%s\n' "$(uname -r)"
	printf 'OBKA_UPDATE_SINGULARITY=%s\n' "$(singularity --version 2>/dev/null || true)"
	printf 'OBKA_UPDATE_PHASE2_PASS\n'
	finish
fi

if [ ! -f "$bundle" ] && ! grep -q '^https_url=.' /etc/obake/update.conf 2>/dev/null; then
	printf 'OBKA_UPDATE_SKIP\n'
	finish
fi

# Phase 1: install the bundle into the inactive slot, either directly from the
# embedded bundle or through the update client (USB preferred, then HTTPS).
[ "$(booted_slot)" = "rootfs.0" ] || fail "phase1 not booted from slot A"
mount_tag A absent || fail "phase1 active slot already tagged"
mount_tag B absent || fail "phase1 inactive slot already tagged"
echo user >/home/obake-update-user-marker 2>/dev/null || fail "user-write"

if [ -f "$bundle" ]; then
	rauc install "$bundle" >/tmp/update.log 2>&1 || fail "install"
	source="embedded"
else
	obake-update apply >/tmp/update.log 2>&1 || fail "client-apply"
	cat /tmp/update.log >/dev/console 2>/dev/null
	if grep -q 'installing .* (USB)' /tmp/update.log; then
		source="usb"
	elif grep -q 'installing .* (HTTPS)' /tmp/update.log; then
		source="https"
	else
		source="unknown"
	fi
fi
rauc status --output-format=shell >/tmp/status.log 2>&1
printf 'OBKA_UPDATE_SOURCE=%s\n' "$source"

mount_tag A absent || fail "active-slot-changed"
mount_tag B present || fail "inactive-not-written"
[ "$(primary_slot)" = "rootfs.1" ] || fail "not-activated"

printf 'OBKA_UPDATE_PHASE1_PASS\n'
: >"$marker"
finish
