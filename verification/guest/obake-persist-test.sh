#!/bin/sh
# Writable-contract persistence test (as User=obake).
#
# Proves login-user persistence and mount topology without writing /etc (the
# SSH user cannot). Slot switch uses obake-update rollback.
#
# Boot 1 (slot A): assert overlay/tmpfs topology; write home + transient /var/tmp
# markers. Power off.
#
# Boot 2 (slot A): assert home survived, transient discarded, topology intact;
# then activate the other slot via rollback.
#
# Boot 3 (slot B): assert home and topology survived the slot switch.
set -u

phase_file="/home/obake/.obake-persist-phase"

fail() { printf 'OBKA_PERSIST_FAIL %s\n' "$1"; exit 1; }
finish() { sync; /usr/bin/systemctl poweroff; exit 0; }

check_topology() {
	[ "$(findmnt -no FSTYPE /etc 2>/dev/null)" = "overlay" ] || return 1
	[ -e /etc/obake/etc-overlay ] || return 1
	[ "$(findmnt -no FSTYPE /var 2>/dev/null)" = "tmpfs" ] || return 1
	mountpoint -q /var/lib/systemd || return 1
	findmnt -no SOURCE /home >/dev/null 2>&1 || return 1
	return 0
}

if [ ! -f "$phase_file" ]; then
	check_topology || fail "topology"
	! touch /etc/obake-persist-should-fail 2>/dev/null || fail "etc-writable"
	echo transient >/var/tmp/obake-transient 2>/dev/null || fail "var-tmp-write"
	echo user >/home/obake/obake-user-marker 2>/dev/null || fail "user-write"
	printf 'OBKA_PERSIST_PHASE1_PASS\n'
	echo 1 >"$phase_file"
	finish
fi

phase="$(cat "$phase_file" 2>/dev/null)"
if [ "$phase" = "1" ]; then
	check_topology || fail "topology-reboot"
	[ ! -e /var/tmp/obake-transient ] || fail "transient-retained"
	[ "$(cat /home/obake/obake-user-marker 2>/dev/null)" = user ] || fail "user-lost-across-reboot"
	printf 'OBKA_PERSIST_PHASE2_PASS\n'
	echo 2 >"$phase_file"
	obake-update rollback >/tmp/obake-persist-rollback.log 2>&1 || fail "rollback"
	finish
fi

# Slot switch: user partition and mount topology must still hold.
check_topology || fail "topology-slot"
[ ! -e /var/tmp/obake-transient ] || fail "transient-retained-slot"
[ "$(cat /home/obake/obake-user-marker 2>/dev/null)" = user ] || fail "user-lost-across-slot"
printf 'OBKA_PERSIST_PHASE3_PASS\n'
rm -f "$phase_file"
finish
