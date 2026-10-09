#!/usr/bin/env bash
#
# obake Buildroot post-fakeroot hook.
#
# Runs inside Buildroot's fakeroot session while assembling the root filesystem,
# so ownership changes are recorded in the image even when the build itself runs
# as a non-root user.
set -euo pipefail

target_dir="${1:?usage: post-fakeroot.sh <target-dir>}"

# Optional build-time password for the obake account. users.txt keeps `*`
# (password disabled); when OBKA_PASSWORD is non-empty, hash it into shadow and
# enable SSH password authentication. Never print the cleartext value.
pw_dropin="${target_dir}/etc/ssh/sshd_config.d/obake-password.conf"
if [ -n "${OBKA_PASSWORD:-}" ]; then
	command -v openssl >/dev/null 2>&1 || {
		printf '[post-fakeroot] error: openssl required to hash OBKA_PASSWORD\n' >&2
		exit 1
	}
	shadow="${target_dir}/etc/shadow"
	[ -f "$shadow" ] || {
		printf '[post-fakeroot] error: %s missing\n' "$shadow" >&2
		exit 1
	}
	hash="$(printf '%s\n' "$OBKA_PASSWORD" | openssl passwd -6 -stdin)"
	[ -n "$hash" ] || {
		printf '[post-fakeroot] error: failed to hash OBKA_PASSWORD\n' >&2
		exit 1
	}
	tmp="$(mktemp)"
	awk -v h="$hash" -F: 'BEGIN { OFS = ":" } $1 == "obake" { $2 = h } { print }' \
		"$shadow" >"$tmp"
	grep -q '^obake:' "$tmp" || {
		rm -f "$tmp"
		printf '[post-fakeroot] error: obake missing from shadow\n' >&2
		exit 1
	}
	cat "$tmp" >"$shadow"
	rm -f "$tmp"
	chmod 640 "$shadow"
	chown 0:0 "$shadow"
	install -d "${target_dir}/etc/ssh/sshd_config.d"
	printf '%s\n' \
		'# Written when OBKA_PASSWORD is set at build time.' \
		'PasswordAuthentication yes' >"$pw_dropin"
	chmod 644 "$pw_dropin"
	chown 0:0 "$pw_dropin"
	printf '[post-fakeroot] obake password set; SSH PasswordAuthentication yes\n' >&2
else
	# Drop a stale drop-in from an earlier password build in the same TARGET_DIR.
	rm -f "$pw_dropin"
fi

# Files copied from the rootfs overlay keep the build user's ownership; polkit
# and sshd's StrictModes require root-owned configuration.
for p in etc/hosts etc/hostname etc/polkit-1 etc/ssh etc/systemd etc/udev \
	etc/jack etc/security/limits.d etc/sysctl.d etc/tmpfiles.d usr/lib/systemd; do
	[ -e "${target_dir}/$p" ] || continue
	chown -R 0:0 "${target_dir}/$p"
done
