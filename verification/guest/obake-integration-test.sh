#!/bin/sh
# End-to-end integration test as User=obake: customize home data -> update ->
# reboot -> forced failed update -> revert, asserting the login-user contract
# and that the user partition is never modified by a failed update.
#
# State lives under /home (writable by obake). Updates go through obake-update.
set -u

state="/home/obake/.obake-integration-state"
good="/opt/obake/good.raucb"
bad="/opt/obake/bad.raucb"

fail() { printf 'OBKA_INTEGRATION_FAIL %s\n' "$1"; exit 1; }
finish() { sync; /usr/bin/systemctl poweroff; exit 0; }

booted() {
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
version() { cat /etc/obake/image-version 2>/dev/null; }
home_sum() { find /home/obake -xdev -type f -exec sha256sum {} + 2>/dev/null | sort; }

# Seed trigger from the image; state must live where obake can write.
if [ ! -f "$state" ] && [ -f /etc/obake/integration-seed ]; then
	echo 1 >"$state" 2>/dev/null || fail "seed-state"
fi
[ -f "$state" ] || { printf 'OBKA_INTEGRATION_SKIP\n'; finish; }

phase="$(cat "$state" 2>/dev/null)"
case "$phase" in
1)
	echo user >/home/obake/obake-user-marker 2>/dev/null || fail "home-write"
	! touch /etc/obake-cfg-should-fail 2>/dev/null || fail "etc-writable"
	echo shape >/home/obake/shape.conf 2>/dev/null || fail "shapes-write"
	home_sum >/home/obake/.obake-home.sha
	obake-update apply "$good" >/tmp/good.log 2>&1 || fail "good-install"
	echo 2 >"$state"
	printf 'OBKA_INTEGRATION_PHASE1_PASS\n'
	finish
	;;
2)
	[ "$(version)" = "0.6.0" ] || fail "not-new-version(ver=$(version))"
	[ "$(cat /home/obake/obake-user-marker 2>/dev/null)" = user ] || fail "home-lost"
	[ "$(cat /home/obake/shape.conf 2>/dev/null)" = shape ] || fail "shapes-lost"
	obake-update apply "$bad" >/tmp/bad.log 2>&1 || fail "bad-install"
	echo 3 >"$state"
	printf 'OBKA_INTEGRATION_PHASE2_PASS\n'
	finish
	;;
3)
	printf 'OBKA_INTEGRATION_PHASE3_REACHED\n'
	echo 4 >"$state"
	finish
	;;
*)
	[ "$(booted)" = "rootfs.1" ] || fail "not-reverted(booted=$(booted))"
	[ "$(version)" = "0.6.0" ] || fail "wrong-version(ver=$(version))"
	[ "$(cat /home/obake/shape.conf 2>/dev/null)" = shape ] || fail "shapes-lost-after-revert"
	[ "$(home_sum)" = "$(cat /home/obake/.obake-home.sha 2>/dev/null)" ] ||
		fail "user-partition-modified"
	rm -f "$state"
	printf 'OBKA_INTEGRATION_PASS\n'
	finish
	;;
esac
