#!/bin/sh
# Writable-contract persistence test.
#
# Boot 1 (slot A): write markers under /etc, a transient /var path, a persisted
# /var subset path, and the user partition. Power off.
#
# Boot 2 (slot A): assert /etc and the persisted /var subset survived, the
# transient /var path was discarded, and the user data survived. Then activate
# the other slot.
#
# Boot 3 (slot B): assert /etc, the persisted /var subset, and user data are
# still present across the slot switch.
set -u

phase_file="/persist/obake-persist-phase"

fail() { printf 'OBKA_PERSIST_FAIL %s\n' "$1"; exit 1; }
finish() { sync; /usr/bin/systemctl poweroff -f; exit 0; }

if [ ! -f "$phase_file" ]; then
	echo etc >/etc/obake-persist-marker 2>/dev/null || fail "etc-write"
	echo transient >/var/tmp/obake-transient 2>/dev/null || fail "var-write"
	mkdir -p /var/lib/systemd
	echo persisted >/var/lib/systemd/obake-persist-marker 2>/dev/null || fail "subset-write"
	echo user >/home/obake-user-marker 2>/dev/null || fail "user-write"
	printf 'OBKA_PERSIST_PHASE1_PASS\n'
	echo 1 >"$phase_file"
	finish
fi

phase="$(cat "$phase_file" 2>/dev/null)"
if [ "$phase" = "1" ]; then
	[ "$(cat /etc/obake-persist-marker 2>/dev/null)" = etc ] || fail "etc-lost-across-reboot"
	[ ! -e /var/tmp/obake-transient ] || fail "transient-retained"
	[ "$(cat /var/lib/systemd/obake-persist-marker 2>/dev/null)" = persisted ] ||
		fail "var-subset-lost-across-reboot"
	[ "$(cat /home/obake-user-marker 2>/dev/null)" = user ] || fail "user-lost-across-reboot"
	printf 'OBKA_PERSIST_PHASE2_PASS\n'
	echo 2 >"$phase_file"
	rauc status mark-active other >/dev/null 2>&1 || fail "mark-active"
	finish
fi

# Slot switch: /etc and persist are shared; the user partition is untouched.
[ "$(cat /etc/obake-persist-marker 2>/dev/null)" = etc ] || fail "etc-lost-across-slot"
[ ! -e /var/tmp/obake-transient ] || fail "transient-retained-slot"
[ "$(cat /var/lib/systemd/obake-persist-marker 2>/dev/null)" = persisted ] ||
	fail "var-subset-lost-across-slot"
[ "$(cat /home/obake-user-marker 2>/dev/null)" = user ] || fail "user-lost-across-slot"
printf 'OBKA_PERSIST_PHASE3_PASS\n'
rm -f "$phase_file"
finish
