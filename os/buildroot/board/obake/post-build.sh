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
if grep -q '^BR2_aarch64=y' "${BR2_CONFIG:-/dev/null}"; then
	arch="aarch64"
elif grep -q '^BR2_x86_64=y' "${BR2_CONFIG:-/dev/null}"; then
	arch="x86_64"
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

# Verification overrides for the update client and health gate.
if [ -n "${MOCK_HEALTH:-}" ] || [ -n "${HEALTH_MAX_ATTEMPTS:-}" ]; then
	printf 'max_attempts=%s\nmock_health=%s\n' \
		"${HEALTH_MAX_ATTEMPTS:-3}" "${MOCK_HEALTH:-pass}" \
		>"${target_dir}/etc/obake/health.conf"
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

# Files copied from the rootfs overlay keep the build user's ownership; polkit
# and sshd's StrictModes require root-owned configuration.
for p in etc/hosts etc/hostname etc/polkit-1 etc/ssh etc/systemd etc/udev \
	etc/jack etc/security/limits.d etc/sysctl.d etc/tmpfiles.d usr/lib/systemd; do
	[ -e "${target_dir}/$p" ] || continue
	chown -R 0:0 "${target_dir}/$p"
done

printf '[post-build] kernel=%s arch=%s image-version=%s\n' \
	"$kver" "$arch" "$image_version"
