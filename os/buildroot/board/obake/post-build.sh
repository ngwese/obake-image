#!/usr/bin/env bash
#
# obake Buildroot post-build hook.
#
# Runs after every package is built and before the root filesystem is
# assembled. It records the built kernel version and the image version under
# /etc/obake and refuses to produce an image whose kernel is not configured for
# realtime (CONFIG_PREEMPT_RT).
set -euo pipefail

target_dir="${1:?usage: post-build.sh <target-dir>}"
extroot="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

image_version="${OBAKE_IMAGE_VERSION:-$(cat "${extroot}/VERSION" 2>/dev/null || echo 0.0.0)}"

# Architecture, read from the Buildroot configuration exported by Buildroot.
arch="unknown"
serial_cons=""
if grep -q '^BR2_aarch64=y' "${BR2_CONFIG:-/dev/null}"; then
	arch="aarch64"
	serial_cons=ttyAMA0
elif grep -q '^BR2_x86_64=y' "${BR2_CONFIG:-/dev/null}"; then
	arch="x86_64"
	serial_cons=ttyS0
fi

board="${OBAKE_BOARD:-}"
if [ -z "$board" ] && [ -n "${BR2_CONFIG:-}" ]; then
	if grep -q '^BR2_TARGET_UBOOT_NEEDS_ROCKCHIP_RKBIN=y' "$BR2_CONFIG"; then
		board=rk35xx
	elif [ "$arch" != "unknown" ]; then
		board="generic-$arch"
	fi
fi
[ "$board" = "rk35xx" ] && serial_cons=ttyS2

# Align getty with CONSOLE so the installed OS presents a login on the same
# console as the installer / UKI cmdline (see console-env.sh).
if [ -n "$serial_cons" ]; then
	# shellcheck source=console-env.sh
	. "$(dirname "${BASH_SOURCE[0]}")/console-env.sh"
	wants="${target_dir}/etc/systemd/system/getty.target.wants"
	install -d "$wants"
	# Drop board- or Buildroot-default getty enables; enable only the selected one.
	rm -f "$wants"/getty@*.service "$wants"/serial-getty@*.service
	ln -sf "/usr/lib/systemd/system/${getty_unit}" "$wants/$getty_unit"
	# Mask the alternate so generators cannot resurrect a conflicting getty.
	system_dir="${target_dir}/etc/systemd/system"
	install -d "$system_dir"
	if [ "$console_mode" = local ]; then
		ln -sfn /dev/null "$system_dir/serial-getty@${serial_cons}.service"
		rm -f "$system_dir/getty@tty1.service"
	else
		ln -sfn /dev/null "$system_dir/getty@tty1.service"
		rm -f "$system_dir/serial-getty@${serial_cons}.service"
	fi
	printf '[post-build] CONSOLE=%s getty=%s\n' "$console_mode" "$getty_unit" >&2
fi

# The version of the kernel actually built, taken from the modules tree.
kver=""
for d in "${target_dir}"/lib/modules/*/; do
	[ -d "$d" ] || continue
	kver="$(basename "$d")"
done
[ -n "$kver" ] || {
	printf '[post-build] error: no kernel modules found in %s/lib/modules\n' \
		"$target_dir" >&2
	exit 1
}

# Refuse an image whose kernel is not realtime.
kconfig=""
for c in "${BASE_DIR:-}"/build/linux-*/.config; do
	[ -f "$c" ] || continue
	kconfig="$c"
done
if [ -z "$kconfig" ] || ! grep -q '^CONFIG_PREEMPT_RT=y' "$kconfig"; then
	printf '[post-build] error: realtime kernel config (CONFIG_PREEMPT_RT) missing\n' >&2
	exit 1
fi

mkdir -p "${target_dir}/etc/obake"
{
	printf 'flavor=rt\n'
	printf 'arch=%s\n' "$arch"
	printf 'image=%s\n' "$kver"
} >"${target_dir}/etc/obake/kernel"
printf '%s\n' "$image_version" >"${target_dir}/etc/obake/image-version"
if [ -n "${IMAGE_TAG:-}" ]; then
	printf '%s\n' "$IMAGE_TAG" >"${target_dir}/etc/obake/image-tag"
else
	rm -f "${target_dir}/etc/obake/image-tag"
fi

# Mount points for the writable contract (persist, user, ESP).
install -d "${target_dir}/persist" "${target_dir}/home" "${target_dir}/boot/efi"

# Record the pinned Singularity CE version for the guest functional checks.
if [ -f "${extroot}/package/singularity/singularity.mk" ] &&
	[ -e "${target_dir}/usr/bin/singularity" ]; then
	sing_ver="$(sed -n 's/^SINGULARITY_VERSION = //p' "${extroot}/package/singularity/singularity.mk")"
	[ -n "$sing_ver" ] && printf 'singularity=%s\n' "$sing_ver" >"${target_dir}/etc/obake/singularity"
fi

# Install the RAUC keyring the update system verifies bundles against.
if [ -n "${RAUC_KEYRING:-}" ] && [ -f "$RAUC_KEYRING" ]; then
	install -d "${target_dir}/etc/rauc"
	install -m 0644 "$RAUC_KEYRING" "${target_dir}/etc/rauc/ca.cert.pem"
fi

# Verification overrides for the update client and health gate. The mock health
# choice is per-slot, so it lives in the rootfs (not the persistent /etc
# overlay, which is shared across slots and would shadow it).
if [ -n "${MOCK_HEALTH:-}" ] || [ -n "${HEALTH_MAX_ATTEMPTS:-}" ]; then
	install -d "${target_dir}/usr/lib/obake"
	printf 'max_attempts=%s\nmock_health=%s\n' \
		"${HEALTH_MAX_ATTEMPTS:-3}" "${MOCK_HEALTH:-pass}" \
		>"${target_dir}/usr/lib/obake/health.mock"
fi
if [ -n "${LOCAL_BUNDLE:-}" ] || [ -n "${UPDATE_URL:-}" ]; then
	printf 'https_url=%s\nusb_prefer=1\nlocal_bundle=%s\n' \
		"${UPDATE_URL:-}" "${LOCAL_BUNDLE:-}" >"${target_dir}/etc/obake/update.conf"
fi

# Install verification guest checks and apply any BREAK fault injection.
bash "${extroot}/board/obake/install-verify.sh" "$target_dir"

# Optional SSH public key for the obake user, provisioned into the image.
if [ -n "${OBKA_SSH_AUTHORIZED_KEY:-}" ] && [ -f "$OBKA_SSH_AUTHORIZED_KEY" ]; then
	install -d "${target_dir}/etc/ssh/authorized_keys.d"
	install -m 0644 "$OBKA_SSH_AUTHORIZED_KEY" \
		"${target_dir}/etc/ssh/authorized_keys.d/obake"
fi

# OpenSSH's packaged sshd_config does not include the drop-in directory, so the
# obake settings under /etc/ssh/sshd_config.d would be ignored. Add the include
# at the top (first-obtained value wins), as distributions do.
sshd_config="${target_dir}/etc/ssh/sshd_config"
if [ -f "$sshd_config" ] &&
	! grep -q '^Include /etc/ssh/sshd_config.d/' "$sshd_config"; then
	sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$sshd_config"
fi

# Root ownership for overlay-copied config is applied in post-fakeroot.sh so a
# non-root build can still record uid 0 in the assembled root filesystem.

printf '[post-build] kernel=%s arch=%s image-version=%s\n' \
	"$kver" "$arch" "$image_version"
