#!/bin/sh
# Health-gate functional test for the verification image.
#
# Boot 1 (slot A): run the update client, which snapshots the shape
# configuration and marks the update pending, then installs the bundle to slot
# B. Assert the snapshot and pending marker exist before the slot is written.
#
# Later boots: report which slot booted and whether the previous configuration
# was restored. The health gate itself runs earlier in boot and prints
# OBKA_HEALTH_PASS / OBKA_HEALTH_RETRY / OBKA_HEALTH_REVERT.
set -u

bundle="/opt/obake/update.raucb"
marker="/persist/obake-health-phase"

fail() {
	printf 'OBKA_HEALTH_TEST_FAIL %s\n' "$1"
	[ -f /tmp/health-apply.log ] && cat /tmp/health-apply.log >/dev/console 2>/dev/null
	exit 1
}
finish() {
	sync
	/usr/bin/systemctl poweroff -f
	exit 0
}

if [ ! -f "$marker" ]; then
	[ -f "$bundle" ] || fail "no-bundle"
	obake-update apply >/tmp/health-apply.log 2>&1 || fail "apply"
	# The snapshot and pending marker must exist before the inactive slot is
	# written.
	ls /persist/obake/snapshots/*/shapes.list >/dev/null 2>&1 || fail "no-snapshot"
	[ -f /persist/obake/health/pending ] || fail "no-pending"
	printf 'OBKA_HEALTH_PHASE1_PASS\n'
	: >"$marker"
	finish
fi

printf 'OBKA_HEALTH_TEST_BOOT booted=%s\n' \
	"$(rauc status 2>/dev/null | sed -n 's/^Booted from: //p')"
[ -f /persist/obake/restored ] && printf 'OBKA_HEALTH_CONFIG_RESTORED\n'
finish
