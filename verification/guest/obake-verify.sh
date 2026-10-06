#!/bin/sh
# Guest functional checks for the obake writable contract. Installed into a
# verification image by build.sh when VERIFY=1, run at boot, and the machine is
# powered off. Prints one OBKA_CHECK line per check and a final verdict the QEMU
# harness matches.
set -u

pin_version="${OBKA_SINGULARITY_VERSION:-4.5.1}"

run() {
	name="$1"
	shift
	if "$@"; then
		printf 'OBKA_CHECK %s=pass\n' "$name"
	else
		printf 'OBKA_CHECK %s=fail\n' "$name"
		fail=1
	fi
}

# Root must be read-only: a write outside the contract has to fail.
check_root_readonly() {
	! touch /obake-root-probe 2>/dev/null
}

# /etc must be a writable overlay backed by the persist partition.
check_etc_overlay() {
	[ "$(findmnt -no FSTYPE /etc 2>/dev/null)" = "overlay" ] || return 1
	echo probe >/etc/obake-etc-probe 2>/dev/null
}

# /var must be a tmpfs with the persisted subset bind-mounted from persist.
check_var_contract() {
	[ "$(findmnt -no FSTYPE /var 2>/dev/null)" = "tmpfs" ] || return 1
	mountpoint -q /var/lib/systemd || return 1
	echo probe >/var/lib/systemd/.obake-probe 2>/dev/null || return 1
	[ -f /persist/var/lib/systemd/.obake-probe ] || return 1
}

# The user partition must be mounted writable at /home.
check_user_partition() {
	findmnt -no SOURCE /home >/dev/null 2>&1 || return 1
	touch /home/obake-user-probe 2>/dev/null
}

# The pinned Singularity CE runtime must be present and match the build stamp.
check_singularity() {
	stamp="$(sed -n 's/^singularity=//p' /etc/obake/singularity 2>/dev/null)"
	[ -n "$stamp" ] || return 1
	[ "$(singularity --version 2>/dev/null)" = "singularity-ce version $stamp" ]
}

# Singularity bind-mounts these files into containers; they must exist.
check_singularity_mounts() {
	[ -e /etc/hosts ] && [ -e /etc/localtime ] && [ -e /etc/resolv.conf ]
}

# DNS must resolve names (systemd-resolved over DHCP).
check_dns() {
	getent hosts deb.debian.org >/dev/null 2>&1
}

# avahi (mDNS) and git must be installed and running.
check_avahi() {
	systemctl is-active --quiet avahi-daemon
}

check_git() {
	command -v git >/dev/null 2>&1
}

# The pinned PREEMPT_RT kernel must be running.
check_realtime_kernel() {
	uname -r | grep -q -- '-rt-'
}

# RAUC must see both A/B root slots through its efi backend.
check_rauc_status() {
	findmnt -no SOURCE /boot/efi >/dev/null 2>&1 || return 1
	out="$(rauc status 2>&1)" || return 1
	printf '%s\n' "$out" | grep -q 'rootfs.0' || return 1
	printf '%s\n' "$out" | grep -q 'rootfs.1' || return 1
}

# Updates are user-initiated: no enabled unit may run the client automatically.
check_update_gated() {
	! grep -rqsE 'obake-update[[:space:]]+apply' \
		/etc/systemd/system /usr/lib/systemd/system 2>/dev/null
}

# The client must report running version, active slot, and pending state.
check_update_status() {
	out="$(obake-update status 2>&1)" || return 1
	printf '%s\n' "$out" | grep -q '^running version:' || return 1
	printf '%s\n' "$out" | grep -q '^active slot:' || return 1
	printf '%s\n' "$out" | grep -q '^pending/activated:' || return 1
}

# A manual rollback must activate the other slot.
check_update_rollback() {
	obake-update rollback >/tmp/obake-rollback.log 2>&1 || return 1
	rauc status 2>/dev/null | grep -q '^Activated: rootfs.1' || return 1
}

# A signed bundle must install to the inactive slot (skipped when no bundle was
# embedded in the verification image).
check_rauc_install() {
	[ -f /opt/obake/update.raucb ] || return 0
	if ! rauc install /opt/obake/update.raucb >/tmp/obake-install.log 2>&1; then
		while IFS= read -r line; do
			echo "OBKA_DBG install: $line"
		done </tmp/obake-install.log
		return 1
	fi
	return 0
}

# A tampered bundle must be rejected and leave the inactive slot unchanged.
check_rauc_reject() {
	[ -f /opt/obake/update.raucb ] || return 0
	before="$(sha256sum /boot/efi/EFI/Linux/obake-b.efi 2>/dev/null | cut -d' ' -f1)"
	cp /opt/obake/update.raucb /tmp/obake-bad.raucb
	printf 'x' >>/tmp/obake-bad.raucb
	if rauc install /tmp/obake-bad.raucb >/tmp/obake-bad.log 2>&1; then
		return 1
	fi
	after="$(sha256sum /boot/efi/EFI/Linux/obake-b.efi 2>/dev/null | cut -d' ' -f1)"
	[ "$before" = "$after" ] || return 1
	return 0
}

fail=0
run root-readonly check_root_readonly
run etc-overlay check_etc_overlay
run var-contract check_var_contract
run user-partition check_user_partition
run singularity check_singularity
run singularity-mounts check_singularity_mounts
run realtime-kernel check_realtime_kernel
run dns check_dns
run avahi check_avahi
run git check_git
run rauc-status check_rauc_status
run update-gated check_update_gated
run update-status check_update_status
run rauc-reject check_rauc_reject
run rauc-install check_rauc_install
run update-rollback check_update_rollback

if [ "$fail" = 0 ]; then
	echo OBKA_VERIFY_PASS
else
	echo OBKA_VERIFY_FAIL
fi
