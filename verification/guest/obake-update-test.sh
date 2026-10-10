#!/bin/sh
# Two-phase RAUC update functional test for the verification image.
#
# Phase 1 (running slot A): install a signed bundle for slot B via
# obake-update, assert the update is activated, then power off.
#
# Phase 2 (running the newly installed slot B): assert the firmware booted the
# updated slot and that its rootfs carries the update image tag.
#
# Both the base image and the update image install this service, so phase 2 can
# run from the freshly installed slot. Runs as User=obake.
set -u

bundle="/opt/obake/update.raucb"
marker="/home/obake/.obake-update-phase1"

fail() {
	printf 'OBKA_UPDATE_FAIL %s\n' "$1"
	[ -f /tmp/update.log ] && cat /tmp/update.log >/dev/console 2>/dev/null
	exit 1
}
finish() {
	sync
	/usr/bin/systemctl poweroff
	exit 0
}

# Slot the running system booted from. RAUC reports this from the EFI boot
# entry; when booted via the removable-media fallback it cannot, so fall back to
# the root partition label on the kernel command line.
booted_slot() {
	s="$(rauc status 2>/dev/null | sed -n 's/^Booted from: \(rootfs\.[01]\).*/\1/p')"
	if [ -n "$s" ]; then
		printf '%s' "$s"
		return
	fi
	case "$(cat /proc/cmdline 2>/dev/null)" in
	*OBKA_ROOT_A*) printf 'rootfs.0' ;;
	*OBKA_ROOT_B*) printf 'rootfs.1' ;;
	esac
}
primary_slot() { rauc status 2>/dev/null | sed -n 's/^Activated: \(rootfs\.[01]\).*/\1/p'; }

# Phase 2: the update must be active after reboot.
if [ -f "$marker" ]; then
	[ "$(booted_slot)" = "rootfs.1" ] || fail "phase2 not booted from slot B"
	[ "$(primary_slot)" = "rootfs.1" ] || fail "phase2 primary not rootfs.1"
	[ -s /etc/obake/image-tag ] || fail "phase2 update tag missing"
	[ "$(cat /home/obake/obake-update-user-marker 2>/dev/null)" = user ] ||
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

# Phase 1: install via the update client (local path or USB/HTTPS discovery).
[ "$(booted_slot)" = "rootfs.0" ] || fail "phase1 not booted from slot A"
echo user >/home/obake/obake-update-user-marker 2>/dev/null || fail "user-write"

if [ -f "$bundle" ]; then
	obake-update apply "$bundle" >/tmp/update.log 2>&1 || fail "install"
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
printf 'OBKA_UPDATE_SOURCE=%s\n' "$source"

[ "$(primary_slot)" = "rootfs.1" ] || fail "not-activated"

printf 'OBKA_UPDATE_PHASE1_PASS\n'
: >"$marker"
finish
