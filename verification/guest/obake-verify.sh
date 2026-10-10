#!/bin/sh
# Guest functional checks for the obake writable contract. Installed into a
# verification image by build.sh when VERIFY=1, run at boot as User=obake, and
# the machine is powered off. Prints one OBKA_CHECK line per check and a final
# verdict the QEMU harness matches.
set -u

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

# Suites must run as the login user so privilege gaps fail CI.
check_running_as_obake() {
	[ "$(id -un 2>/dev/null)" = "obake" ]
}

# Root must be mounted read-only. As obake, touch("/") fails on permissions
# even when the mount is rw, so assert the mount options instead.
check_root_readonly() {
	findmnt -no OPTIONS / 2>/dev/null | tr ',' '\n' | grep -qx ro
}

# /etc overlay is present; the login user does not write it.
check_etc_overlay() {
	[ "$(findmnt -no FSTYPE /etc 2>/dev/null)" = "overlay" ] || return 1
	[ -e /etc/obake/etc-overlay ]
}

# Login user cannot write /etc (SSH directory-contract reality).
check_etc_denied() {
	! touch /etc/obake-should-fail 2>/dev/null
}

# /var must be a tmpfs with the persisted subset bind-mounted from persist.
check_var_contract() {
	[ "$(findmnt -no FSTYPE /var 2>/dev/null)" = "tmpfs" ] || return 1
	mountpoint -q /var/lib/systemd
}

# The user partition must be mounted writable at /home for obake.
check_user_partition() {
	findmnt -no SOURCE /home >/dev/null 2>&1 || return 1
	touch /home/obake/obake-user-probe 2>/dev/null
}

# The pinned Singularity CE runtime must be present and match the build stamp.
# Setuid helper + conf must be installed for kernel SquashFS mounts.
# Avoid `stat -c` — this image's busybox does not provide the stat applet.
check_singularity() {
	stamp="$(sed -n 's/^singularity=//p' /etc/obake/singularity 2>/dev/null)"
	[ -n "$stamp" ] || return 1
	[ "$(singularity --version 2>/dev/null)" = "singularity-ce version $stamp" ] || return 1
	suid=/usr/libexec/singularity/bin/starter-suid
	[ -f "$suid" ] || return 1
	# Setuid bit set; not writable by obake (implies root-owned 4755).
	[ -u "$suid" ] || return 1
	! test -w "$suid" || return 1
	conf=/etc/singularity/singularity.conf
	[ -f "$conf" ] || return 1
	# Conf not writable by obake (root-owned, not group/other-writable).
	! test -w "$conf" || return 1
	grep -q '^allow setuid = yes$' "$conf" || return 1
	grep -q '^allow kernel squashfs = yes$' "$conf" || return 1
}

# Singularity bind-mounts these files into containers; they must exist.
check_singularity_mounts() {
	[ -e /etc/hosts ] && [ -e /etc/localtime ] && [ -e /etc/resolv.conf ]
}

# Local SIF run must use setuid + kernel SquashFS (not FUSE/squashfuse).
check_singularity_run() {
	[ -f /opt/obake/verify.sif ] || return 1
	if ! singularity -d run /opt/obake/verify.sif >/tmp/obake-sif-run.log 2>&1; then
		printf 'singularity-run: command failed\n' >&2
		tail -n 40 /tmp/obake-sif-run.log >&2 || true
		return 1
	fi
	# SingularityCE logs this INFO line only when preparing a FUSE image mount.
	if grep -F 'Mounting image with FUSE.' /tmp/obake-sif-run.log; then
		printf 'singularity-run: FUSE mount used\n' >&2
		return 1
	fi
	if grep -Eiq 'squashfuse|falling back to extraction' /tmp/obake-sif-run.log; then
		printf 'singularity-run: squashfuse/extract fallback\n' >&2
		return 1
	fi
}

# /tmp must be a nosuid tmpfs that still allows device nodes, and a default
# fakeroot build (no temporary-directory override) must not warn about that.
check_tmp_singularity_build() {
	[ -f /opt/obake/verify.sif ] || return 1
	[ "$(findmnt -no FSTYPE /tmp 2>/dev/null)" = "tmpfs" ] || return 1
	opts="$(findmnt -no OPTIONS /tmp 2>/dev/null)" || return 1
	printf '%s\n' "$opts" | tr ',' '\n' | grep -qx nosuid || return 1
	if printf '%s\n' "$opts" | tr ',' '\n' | grep -qx nodev; then
		printf 'tmp-singularity-build: nodev on /tmp\n' >&2
		return 1
	fi
	if printf '%s\n' "$opts" | tr ',' '\n' | grep -qx noexec; then
		printf 'tmp-singularity-build: noexec on /tmp\n' >&2
		return 1
	fi
	touch /tmp/obake-tmp-probe 2>/dev/null || return 1
	rm -f /tmp/obake-tmp-probe

	def=/tmp/obake-nodev.def
	out=/tmp/obake-nodev.sif
	log=/tmp/obake-nodev.log
	cat >"$def" <<'EOF'
Bootstrap: localimage
From: /opt/obake/verify.sif
EOF
	unset TMPDIR SINGULARITY_TMPDIR APPTAINER_TMPDIR
	if ! singularity build --fakeroot --force "$out" "$def" >"$log" 2>&1; then
		printf 'tmp-singularity-build: build failed\n' >&2
		tail -n 40 "$log" >&2 || true
		return 1
	fi
	if grep -F "'nodev' mount option set on /tmp" "$log"; then
		printf 'tmp-singularity-build: nodev warning\n' >&2
		return 1
	fi
	[ -f "$out" ]
}

# Fakeroot needs seeded /etc/subuid and /etc/subgid for obake.
check_singularity_fakeroot() {
	[ -f /opt/obake/verify.sif ] || return 1
	uid_line="$(grep -E '^obake:[0-9]+:[0-9]+$' /etc/subuid 2>/dev/null)" || {
		printf 'singularity-fakeroot: missing /etc/subuid mapping\n' >&2
		return 1
	}
	gid_line="$(grep -E '^obake:[0-9]+:[0-9]+$' /etc/subgid 2>/dev/null)" || {
		printf 'singularity-fakeroot: missing /etc/subgid mapping\n' >&2
		return 1
	}
	uid_count="${uid_line##*:}"
	gid_count="${gid_line##*:}"
	[ "$uid_count" -ge 65536 ] 2>/dev/null || return 1
	[ "$gid_count" -ge 65536 ] 2>/dev/null || return 1
	out="$(singularity exec --fakeroot /opt/obake/verify.sif id -u 2>/tmp/obake-sif-fakeroot.log)" || {
		printf 'singularity-fakeroot: exec failed\n' >&2
		tail -n 40 /tmp/obake-sif-fakeroot.log >&2 || true
		return 1
	}
	[ "$out" = "0" ] || {
		printf 'singularity-fakeroot: got uid=%s\n' "$out" >&2
		return 1
	}
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

# ESP must be readable/listable by obake without sudo (df, ls /boot/efi).
# Non-root write must still fail; ownership stays root via VFAT uid=0.
check_esp_access() {
	findmnt -no SOURCE /boot/efi >/dev/null 2>&1 || return 1
	[ -x /boot ] || return 1
	[ -r /boot/efi ] || return 1
	ls /boot/efi >/dev/null 2>&1 || return 1
	probe="/boot/efi/.obake-esp-writetest-$$"
	if touch "$probe" 2>/dev/null; then
		rm -f "$probe" 2>/dev/null || true
		return 1
	fi
	return 0
}

# Updates are user-initiated: no enabled unit may run the client automatically.
check_update_gated() {
	! grep -rqsE 'obake-update[[:space:]]+apply' \
		/etc/systemd/system /usr/lib/systemd/system 2>/dev/null
}

# Root must be locked so empty-password su does not grant a root shell.
check_root_locked() {
	# Locked root rejects empty-password su; do not read /etc/shadow.
	if printf '\n' | su -c 'true' root >/tmp/obake-su-root.log 2>&1; then
		return 1
	fi
	return 0
}

# obake may invoke the update client and a general shell via passwordless sudo.
check_update_sudo() {
	sudo -n /usr/bin/obake-update status >/tmp/obake-sudo-update.log 2>&1 || return 1
	sudo -n /bin/sh -c true >/tmp/obake-sudo-shell.log 2>&1 || return 1
	return 0
}

# Wired links must not be required for network-online (uncabled boot is normal).
check_optional_network_online() {
	net='/etc/systemd/network/20-obake-wired.network'
	[ -f "$net" ] || return 1
	grep -qx 'RequiredForOnline=no' "$net"
}

# Removable-media automount path is ready (USB insert is hardware-dependent).
# /media must be a writable mount root, not a directory on the read-only root.
check_media_automount() {
	[ -x /usr/libexec/obake/media-automount ] || return 1
	[ -f /etc/udev/rules.d/99-obake-media-automount.rules ] || return 1
	[ -f /etc/systemd/system/obake-media-automount@.service ] ||
		[ -f /usr/lib/systemd/system/obake-media-automount@.service ] || return 1
	findmnt -n /media >/dev/null 2>&1 || return 1
	probe="/media/.obake-media-writetest-$$"
	sudo -n mkdir "$probe" || return 1
	sudo -n rmdir "$probe" || return 1
	return 0
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

# Kernel release carries board LOCALVERSION (when defined) and -g<sha>[-dirty]
# (or -gnogit when the build cannot read git metadata).
check_kernel_identity() {
	rel="$(uname -r)"
	printf '%s\n' "$rel" | grep -Eq '\-g([0-9a-f]+|nogit)(-dirty)?$' || return 1
	board="$(sed -n 's/^board=//p' /etc/obake/board 2>/dev/null)"
	case "$board" in
	qdl)
		printf '%s\n' "$rel" | grep -q -- '-qdl-g' || return 1
		;;
	generic | generic-x86_64 | generic-aarch64)
		printf '%s\n' "$rel" | grep -q -- '-generic-g' || return 1
		;;
	rk35xx)
		printf '%s\n' "$rel" | grep -q -- '-rk35xx' && return 1
		;;
	*)
		# Unknown board: still require git provenance (checked above).
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
	if ! obake-update apply /opt/obake/update.raucb >/tmp/obake-install.log 2>&1; then
		while IFS= read -r line; do
			echo "OBKA_DBG install: $line"
		done </tmp/obake-install.log
		return 1
	fi
	return 0
}

# A tampered bundle must be rejected and leave the active slot unchanged.
check_rauc_reject() {
	[ -f /opt/obake/update.raucb ] || return 0
	before="$(obake-update status 2>/dev/null | sed -n 's/^pending\/activated: //p')"
	cp /opt/obake/update.raucb /home/obake/obake-bad.raucb
	printf 'x' >>/home/obake/obake-bad.raucb
	if obake-update apply /home/obake/obake-bad.raucb >/tmp/obake-bad.log 2>&1; then
		return 1
	fi
	after="$(obake-update status 2>/dev/null | sed -n 's/^pending\/activated: //p')"
	[ "$before" = "$after" ] || return 1
	return 0
}

fail=0
run as-obake check_running_as_obake
run root-readonly check_root_readonly
run etc-overlay check_etc_overlay
run etc-denied check_etc_denied
run var-contract check_var_contract
run user-partition check_user_partition
run singularity check_singularity
run singularity-mounts check_singularity_mounts
run singularity-run check_singularity_run
run singularity-fakeroot check_singularity_fakeroot
run tmp-singularity-build check_tmp_singularity_build
run ca-certificates check_ca_certificates
run realtime-kernel check_realtime_kernel
run dns check_dns
run avahi check_avahi
run git check_git
run rauc-status check_rauc_status
run esp-access check_esp_access
run update-gated check_update_gated
run root-locked check_root_locked
run update-sudo check_update_sudo
run media-automount check_media_automount
run optional-network-online check_optional_network_online
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
