#!/bin/sh
# End-to-end integration test: install -> customize -> update -> reboot ->
# forced failed update -> revert, asserting the writable contract and that the
# user partition is never modified.
#
# State is kept on the persist partition. The service only acts once the
# trigger file exists, so the installer medium is unaffected.
set -u

state="/persist/obake-integration"
good="/opt/obake/good.raucb"
bad="/opt/obake/bad.raucb"

fail() { printf 'OBKA_INTEGRATION_FAIL %s\n' "$1"; exit 1; }
finish() { sync; /usr/bin/systemctl poweroff -f; exit 0; }
booted() { rauc status 2>/dev/null | sed -n 's/^Booted from: \(rootfs\.[01]\).*/\1/p'; }
version() { cat /etc/obake/image-version 2>/dev/null; }
home_sum() { find /home -xdev -type f -exec sha256sum {} + 2>/dev/null | sort; }

# Mark the update pending so the health gate validates the next boot.
begin_update() { # begin_update <snapshot-id>
	/usr/libexec/obake/obake-launcher snapshot "$1" >/dev/null 2>&1 || fail "snapshot"
	mkdir -p /persist/obake/health
	printf 'snapshot=%s\nattempts=0\n' "$1" >/persist/obake/health/pending
}

# Without the trigger file (installer medium, non-integration builds) do nothing.
[ -f "$state" ] || { printf 'OBKA_INTEGRATION_SKIP\n'; finish; }

phase="$(cat "$state" 2>/dev/null)"
case "$phase" in
1)
	# Customize: user data, persistent /etc, and shape configuration.
	echo user >/home/obake-user-marker 2>/dev/null || fail "home-write"
	echo etc >/etc/obake-cfg-marker 2>/dev/null || fail "etc-write"
	mkdir -p /persist/shapes
	echo shape >/persist/shapes/shape.conf 2>/dev/null || fail "shapes-write"
	home_sum >/persist/obake-home.sha
	begin_update "integration-1"
	rauc install "$good" >/tmp/good.log 2>&1 || fail "good-install"
	echo 2 >"$state"
	printf 'OBKA_INTEGRATION_PHASE1_PASS\n'
	finish
	;;
2)
	[ "$(version)" = "0.5.0" ] || fail "not-new-version(ver=$(version))"
	[ "$(cat /etc/obake-cfg-marker 2>/dev/null)" = etc ] || fail "etc-lost"
	[ "$(cat /home/obake-user-marker 2>/dev/null)" = user ] || fail "home-lost"
	[ "$(cat /persist/shapes/shape.conf 2>/dev/null)" = shape ] || fail "shapes-lost"
	begin_update "integration-2"
	rauc install "$bad" >/tmp/bad.log 2>&1 || fail "bad-install"
	echo 3 >"$state"
	printf 'OBKA_INTEGRATION_PHASE2_PASS\n'
	finish
	;;
3)
	# The health gate reverted this failing slot; record and move on.
	printf 'OBKA_INTEGRATION_PHASE3_REACHED\n'
	echo 4 >"$state"
	finish
	;;
*)
	[ "$(booted)" = "rootfs.1" ] || fail "not-reverted(booted=$(booted))"
	[ "$(version)" = "0.5.0" ] || fail "wrong-version(ver=$(version))"
	[ "$(cat /etc/obake-cfg-marker 2>/dev/null)" = etc ] || fail "etc-lost-after-revert"
	[ "$(cat /persist/shapes/shape.conf 2>/dev/null)" = shape ] || fail "shapes-lost-after-revert"
	[ "$(home_sum)" = "$(cat /persist/obake-home.sha 2>/dev/null)" ] ||
		fail "user-partition-modified"
	rm -f "$state"
	printf 'OBKA_INTEGRATION_PASS\n'
	finish
	;;
esac
