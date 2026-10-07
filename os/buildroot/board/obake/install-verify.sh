#!/usr/bin/env bash
#
# Install verification guest checks and apply fault injection into the target
# rootfs. Mirrors the Debian build's install_verify/apply_break so the same
# harnesses drive a Buildroot image.
#
# Environment:
#   VERIFY=1              install the base guest functional checks
#   VERIFY_HEALTH=1       install the health-gate functional test
#   VERIFY_INTEGRATION=1  install the integration test
#   VERIFY_PERSIST=1      install the writable-contract persistence test
#   VERIFY_UPDATE=1       install the RAUC update functional test
#   VERIFY_UPDATE_BUNDLE  path to a bundle to embed at /opt/obake/update.raucb
#   VERIFY_INTEGRATION_GOOD/BAD  bundles to embed for the integration test
#   BREAK=ro|etc|var|user inject a fault so the matching check must fail
set -euo pipefail

target_dir="${1:?usage: install-verify.sh <target-dir>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guest="$(cd "$here/../../../../verification/guest" && pwd)"

verify="${VERIFY:-0}"
break="${BREAK:-}"

log() { printf '[verify] %s\n' "$*" >&2; }

apply_break() {
	[ -n "$break" ] || return 0
	case "$break" in
	ro) log "BREAK: root will be mounted read-write" ;;
	etc) log "BREAK: disabling the /etc overlay"; rm -f "$target_dir/etc/obake/etc-overlay" ;;
	var) log "BREAK: /var will not be tmpfs"; sed -i '\#tmpfs[[:space:]]*/var#d' "$target_dir/etc/fstab" ;;
	user) log "BREAK: /home will not be mounted"; sed -i '\#OBKA_USER#d' "$target_dir/etc/fstab" ;;
	*) log "unknown BREAK value: $break"; exit 1 ;;
	esac
}

install_service() { # <name> <script> <after>
	local name="$1" script="$2" after="$3"
	install -m 0755 "$guest/$script" "$target_dir/usr/libexec/obake/$script"
	cat >"$target_dir/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=obake $name
After=$after multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/obake/$script
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
	install -d "$target_dir/etc/systemd/system/multi-user.target.wants"
	ln -sf "/etc/systemd/system/$name.service" \
		"$target_dir/etc/systemd/system/multi-user.target.wants/$name.service"
}

embed_bundle() { # <src> <dst-name>
	[ -n "$1" ] && [ -f "$1" ] || return 0
	install -d "$target_dir/opt/obake"
	install -m 0644 "$1" "$target_dir/opt/obake/$2"
}

apply_break

[ "$verify" = "1" ] || exit 0

install -d "$target_dir/usr/libexec/obake"

if [ "${VERIFY_HEALTH:-0}" = "1" ]; then
	log "installing health-gate functional test"
	embed_bundle "${VERIFY_UPDATE_BUNDLE:-}" update.raucb
	install_service obake-health-test obake-health-test.sh obake-health-gate.service
	exit 0
fi

if [ "${VERIFY_INTEGRATION:-0}" = "1" ]; then
	log "installing integration test"
	embed_bundle "${VERIFY_INTEGRATION_GOOD:-}" good.raucb
	embed_bundle "${VERIFY_INTEGRATION_BAD:-}" bad.raucb
	install -m 0755 "$guest/obake-integration-test.sh" "$target_dir/usr/libexec/obake/obake-integration-test.sh"
	cat >"$target_dir/etc/systemd/system/obake-integration-test.service" <<'EOF'
[Unit]
Description=obake integration test
After=obake-health-gate.service obake-runtime.target multi-user.target
Wants=multi-user.target
ConditionPathExists=/persist/obake-integration

[Service]
Type=oneshot
ExecStart=/usr/libexec/obake/obake-integration-test.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
	install -d "$target_dir/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/obake-integration-test.service \
		"$target_dir/etc/systemd/system/multi-user.target.wants/obake-integration-test.service"
	exit 0
fi

if [ "${VERIFY_PERSIST:-0}" = "1" ]; then
	log "installing writable-contract persistence test"
	install_service obake-persist-test obake-persist-test.sh obake-persist-var.service
	exit 0
fi

if [ -n "${VERIFY_UPDATE_BUNDLE:-}" ] || [ "${VERIFY_UPDATE:-0}" = "1" ]; then
	log "installing RAUC update functional test"
	embed_bundle "${VERIFY_UPDATE_BUNDLE:-}" update.raucb
	install_service obake-update-test obake-update-test.sh obake-efi-entries.service
	exit 0
fi

log "installing guest functional checks"
install -m 0755 "$guest/obake-verify.sh" "$target_dir/usr/libexec/obake/obake-verify.sh"
cat >"$target_dir/etc/systemd/system/obake-verify.service" <<'EOF'
[Unit]
Description=obake guest functional checks
After=multi-user.target network-online.target
Wants=multi-user.target network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/libexec/obake/obake-verify.sh; rc=$?; echo "OBKA_VERIFY_EXIT=$rc"; sync; /usr/bin/systemctl poweroff -f'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
install -d "$target_dir/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/obake-verify.service \
	"$target_dir/etc/systemd/system/multi-user.target.wants/obake-verify.service"
