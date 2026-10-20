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

# The version of the kernel actually built. Prefer linux's kernel.release
# (LOCALVERSION is -<board>-<rev>) so a stale
# lib/modules/<old> tree from an earlier build cannot win the scan.
kver=""
kconfig=""
krelease=""
for d in "${BASE_DIR:-}"/build/linux-*/; do
	[ -d "$d" ] || continue
	[ -f "${d}.config" ] && kconfig="${d}.config"
	[ -f "${d}include/config/kernel.release" ] &&
		krelease="$(tr -d '[:space:]' <"${d}include/config/kernel.release")"
done
if [ -n "$krelease" ]; then
	kver="$krelease"
elif [ -d "${target_dir}/lib/modules" ]; then
	for d in "${target_dir}"/lib/modules/*/; do
		[ -d "$d" ] || continue
		kver="$(basename "$d")"
	done
fi
[ -n "$kver" ] || {
	printf '[post-build] error: no kernel release / modules found\n' >&2
	exit 1
}
mod_dir=""
if [ -d "${target_dir}/lib/modules/${kver}" ]; then
	mod_dir="${target_dir}/lib/modules/${kver}"
elif [ -d "${target_dir}/usr/lib/modules/${kver}" ]; then
	mod_dir="${target_dir}/usr/lib/modules/${kver}"
fi
[ -n "$mod_dir" ] || {
	printf '[post-build] error: modules missing for kernel %s\n' "$kver" >&2
	exit 1
}
# Drop leftover module trees from prior LOCALVERSION values.
for d in "${target_dir}"/lib/modules/*/ "${target_dir}"/usr/lib/modules/*/; do
	[ -d "$d" ] || continue
	[ "$(basename "$d")" = "$kver" ] && continue
	rm -rf "$d"
done

# Refuse an image whose kernel is not realtime.
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

# Brand the image as obake-os. Buildroot writes a Buildroot os-release during
# target-finalize before this script runs; replace it with project identity.
# Also rewrite /etc/issue so incremental builds pick up the banner even when
# BR2_TARGET_GENERIC_ISSUE has not yet been re-applied to an existing tree.
git_rev_helper="${extroot}/../scripts/image-git-rev.sh"
git_sha="$("$git_rev_helper" sha)"
git_dirty="$("$git_rev_helper" dirty)"
version_id="${image_version}-g${git_sha}${git_dirty}"
os_release="${target_dir}/usr/lib/os-release"
{
	printf 'NAME=obake-os\n'
	printf 'ID=obake-os\n'
	printf 'VERSION=%s\n' "$image_version"
	printf 'VERSION_ID=%s\n' "$version_id"
	printf 'PRETTY_NAME="obake-os %s"\n' "$version_id"
} >"$os_release"
ln -sfn ../usr/lib/os-release "${target_dir}/etc/os-release"
printf 'Welcome to obake-os\n' >"${target_dir}/etc/issue"
if ! grep -q '^NAME=obake-os$' "$os_release" ||
	grep -q '^NAME=Buildroot$' "$os_release"; then
	printf '[post-build] error: os-release branding failed\n' >&2
	exit 1
fi
if ! grep -q 'Welcome to obake-os' "${target_dir}/etc/issue" ||
	grep -q 'Welcome to Buildroot' "${target_dir}/etc/issue"; then
	printf '[post-build] error: /etc/issue branding failed\n' >&2
	exit 1
fi
printf '[post-build] os-release NAME=obake-os VERSION=%s VERSION_ID=%s\n' \
	"$image_version" "$version_id" >&2

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

# Merge build-time extra root CAs into the system trust store.
# Buildroot's ca-certificates finalize hook runs before post-build (and
# before this script can clear stale drop-ins in an incremental TARGET_DIR)
# and removes update-ca-certificates from the target. Clear the local
# drop-in, install any source extras, then always regenerate the bundle
# the same way CA_CERTIFICATES_GEN_BUNDLE does.
extra_ca_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/extra-ca-certificates"
local_ca="${target_dir}/usr/share/ca-certificates/local"
rm -rf "$local_ca"
shopt -s nullglob
extra_certs=()
[ -d "$extra_ca_dir" ] && extra_certs=("$extra_ca_dir"/*.crt)
shopt -u nullglob
if [ "${#extra_certs[@]}" -gt 0 ]; then
	install -d "$local_ca"
	for cert in "${extra_certs[@]}"; do
		install -m 0644 "$cert" "$local_ca/$(basename "$cert")"
	done
fi
if [ -d "${target_dir}/usr/share/ca-certificates" ]; then
	c_rehash="${HOST_DIR:?HOST_DIR unset}/bin/c_rehash"
	[ -x "$c_rehash" ] || {
		printf '[post-build] error: %s missing (host-openssl)\n' \
			"$c_rehash" >&2
		exit 1
	}
	build_dir="${BUILD_DIR:-${BASE_DIR:?BASE_DIR unset}/build}"
	rm -f "${target_dir}/etc/ssl/certs/"*
	(
		cd "$target_dir"
		for i in $(find usr/share/ca-certificates -name '*.crt' |
			LC_COLLATE=C sort); do
			ln -sf "../../../$i" \
				"etc/ssl/certs/$(basename "$i" .crt).pem"
			cat "$i"
		done
	) >"${build_dir}/ca-certificates.crt"
	"$c_rehash" "${target_dir}/etc/ssl/certs"
	install -D -m 0644 "${build_dir}/ca-certificates.crt" \
		"${target_dir}/etc/ssl/certs/ca-certificates.crt"
	printf '[post-build] system CA store: %d extra certificate(s)\n' \
		"${#extra_certs[@]}" >&2
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

# Shared EFI slot reconcile, also used by the installer image (a copy of
# this rootfs). install.sh and efi-entries.sh both exec this path.
install -D -m 0755 "${extroot}/../scripts/efi-boot-entries.sh" \
	"${target_dir}/usr/libexec/obake/efi-boot-entries.sh"

# Install verification guest checks and apply any BREAK fault injection.
bash "${extroot}/board/obake/install-verify.sh" "$target_dir"

# No build-time authorized key is baked into the rootfs: the key seed is
# provisioned into the obake user's home on the user partition at install (or
# disk assembly), so the user can replace it. The sshd config still honors
# /etc/ssh/authorized_keys.d/%u as an empty operator provisioning fallback.

# OpenSSH's packaged sshd_config does not include the drop-in directory, so the
# obake settings under /etc/ssh/sshd_config.d would be ignored. Add the include
# at the top (first-obtained value wins), as distributions do.
sshd_config="${target_dir}/etc/ssh/sshd_config"
if [ -f "$sshd_config" ] &&
	! grep -q '^Include /etc/ssh/sshd_config.d/' "$sshd_config"; then
	sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$sshd_config"
fi

# Retired no-PAM workarounds: Buildroot overlays do not delete files that were
# removed from the overlay source, so wipe them from a dirty target explicitly.
rm -f "${target_dir}/etc/profile.d/obake-user-bus.sh"
rm -f "${target_dir}/usr/lib/systemd/system/user@.service.d/20-obake-xdg-runtime.conf"
if [ -d "${target_dir}/usr/lib/systemd/system/user@.service.d" ] &&
	[ -z "$(find "${target_dir}/usr/lib/systemd/system/user@.service.d" \
		-mindepth 1 -print -quit)" ]; then
	rmdir "${target_dir}/usr/lib/systemd/system/user@.service.d"
fi

# With linux-pam selected, OpenSSH should set UsePAM yes; enforce it so an
# incremental rebuild cannot leave UsePAM no after a PAM-enabled openssh.
if [ -f "$sshd_config" ]; then
	if grep -qE '^#?UsePAM ' "$sshd_config"; then
		sed -i 's/^#\?UsePAM .*/UsePAM yes/' "$sshd_config"
	else
		printf 'UsePAM yes\n' >>"$sshd_config"
	fi
fi

# Root ownership for overlay-copied config is applied in post-fakeroot.sh so a
# non-root build can still record uid 0 in the assembled root filesystem.

printf '[post-build] kernel=%s arch=%s image-version=%s\n' \
	"$kver" "$arch" "$image_version"
