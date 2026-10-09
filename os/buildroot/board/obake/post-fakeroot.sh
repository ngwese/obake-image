#!/usr/bin/env bash
#
# obake Buildroot post-fakeroot hook.
#
# Runs inside Buildroot's fakeroot session while assembling the root filesystem,
# so ownership changes are recorded in the image even when the build itself runs
# as a non-root user.
set -euo pipefail

target_dir="${1:?usage: post-fakeroot.sh <target-dir>}"

# Files copied from the rootfs overlay keep the build user's ownership; polkit
# and sshd's StrictModes require root-owned configuration.
for p in etc/hosts etc/hostname etc/polkit-1 etc/ssh etc/systemd etc/udev \
	etc/jack etc/security/limits.d etc/sysctl.d etc/tmpfiles.d usr/lib/systemd; do
	[ -e "${target_dir}/$p" ] || continue
	chown -R 0:0 "${target_dir}/$p"
done
