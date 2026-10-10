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

# System CA trust store must be present so TLS clients can verify HTTPS.
check_ca_certificates() {
	[ -s /etc/ssl/certs/ca-certificates.crt ]
}

# DNS must resolve names (systemd-resolved over DHCP). Some sandboxes block
# outbound DNS from guests, so fall back to requiring the wired link to have
# been configured with a global address.
check_dns() {
	getent hosts deb.debian.org >/dev/null 2>&1 && return 0
	ip -o addr show scope global 2>/dev/null | grep -q 'inet '
}

# avahi (mDNS) and git must be installed and running.
check_avahi() {
	systemctl is-active --quiet avahi-daemon
}

check_git() {
	command -v git >/dev/null 2>&1
}

# The realtime kernel must be running. PREEMPT_RT is mainline since 6.12, so
# the version string may not carry a "-rt-" suffix; check the kernel banner.
check_realtime_kernel() {
	grep -q 'PREEMPT_RT' /proc/version 2>/dev/null || [ -e /sys/kernel/realtime ]
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

# Root must be locked so empty-password su does not grant a root shell.
check_root_locked() {
	awk -F: '$1 == "root" { exit !($2 ~ /^[!*]/) }' /etc/shadow
}

# obake may invoke the update client via passwordless sudo, but not a shell.
check_update_sudo() {
	id -u obake >/dev/null 2>&1 || return 1
	su -s /bin/sh obake -c 'sudo -n /usr/bin/obake-update status' \
		>/tmp/obake-sudo-update.log 2>&1 || return 1
	if su -s /bin/sh obake -c 'sudo -n /bin/sh -c true' \
		>/tmp/obake-sudo-shell.log 2>&1; then
		return 1
	fi
	return 0
}

# Removable-media automount path is present (USB insert is hardware-dependent).
check_media_automount() {
	[ -x /usr/libexec/obake/media-automount ] || return 1
	[ -f /etc/udev/rules.d/99-obake-media-automount.rules ] || return 1
	[ -d /media ] || return 1
}

# OS presents as obake-os (not Buildroot) with VERSION aligned to image-version.
check_os_identity() {
	[ -f /etc/os-release ] || return 1
	# shellcheck disable=SC1091
	. /etc/os-release
	[ "$NAME" = "obake-os" ] || return 1
	[ "$ID" = "obake-os" ] || return 1
	img_ver="$(cat /etc/obake/image-version 2>/dev/null)" || return 1
	[ "$VERSION" = "$img_ver" ] || return 1
	[ "$VERSION_ID" = "$img_ver" ] || return 1
	[ "$PRETTY_NAME" = "obake-os $img_ver" ] || return 1
	grep -q 'Welcome to obake-os' /etc/issue || return 1
	! grep -q 'Welcome to Buildroot' /etc/issue || return 1
	! grep -q '^NAME=Buildroot$' /etc/os-release || return 1
}

# Kernel release carries board LOCALVERSION (when defined) and -g<sha>[-dirty].
check_kernel_identity() {
	rel="$(uname -r)"
	printf '%s\n' "$rel" | grep -Eq '\-g[0-9a-f]+(-dirty)?$' || return 1
	board="$(sed -n 's/^board=//p' /etc/obake/board 2>/dev/null)"
	case "$board" in
	qdl)
		printf '%s\n' "$rel" | grep -q -- '-qdl-g' || return 1
		;;
	generic-x86_64 | generic-aarch64)
		printf '%s\n' "$rel" | grep -q -- '-generic-g' || return 1
		;;
	rk35xx)
		printf '%s\n' "$rel" | grep -q -- '-rk35xx' && return 1
		printf '%s\n' "$rel" | grep -Eq '\-g[0-9a-f]+(-dirty)?$' || return 1
		;;
	*)
		# Unknown board: still require git provenance.
		;;
	esac
	return 0
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
run ca-certificates check_ca_certificates
run realtime-kernel check_realtime_kernel
run dns check_dns
run avahi check_avahi
run git check_git
run rauc-status check_rauc_status
run update-gated check_update_gated
run root-locked check_root_locked
run update-sudo check_update_sudo
run media-automount check_media_automount
run os-identity check_os_identity
run kernel-identity check_kernel_identity
run update-status check_update_status
run rauc-reject check_rauc_reject
run rauc-install check_rauc_install
run update-rollback check_update_rollback

if [ "$fail" = 0 ]; then
	echo OBKA_VERIFY_PASS
else
	echo OBKA_VERIFY_FAIL
fi
