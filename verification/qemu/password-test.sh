#!/usr/bin/env bash
set -euo pipefail

# Optional build-time password verification. Builds once without OBKA_PASSWORD
# and asserts password login stays disabled, then builds with OBKA_PASSWORD,
# boots under QEMU, and logs in as obake over SSH using that password
# (password authentication only — no authorized key).
#
# Usage: password-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

arch="${1:-native}"
board="$(obka_board "$arch")"
out="${OUT_BASE:-$image_root/_verify/$OBKA_ARCH/password}"
boot_timeout="${SSH_BOOT_TIMEOUT:-180}"
ssh_port="${PASSWORD_TEST_PORT:-2223}"
test_password="${OBKA_TEST_PASSWORD:-obake-test-pw}"

log() { printf '[password-test] %s\n' "$*" >&2; }
fail() { printf '[password-test] FAIL: %s\n' "$*" >&2; exit 1; }

# Extract a path from a Buildroot rootfs tarball (leading ./ optional).
tar_cat() {
	local archive="$1" path="$2"
	if tar -xOf "$archive" "./$path" 2>/dev/null; then
		return 0
	fi
	tar -xOf "$archive" "$path"
}

shadow_field() {
	local archive="$1" field
	field="$(tar_cat "$archive" etc/shadow | awk -F: '$1 == "obake" { print $2; exit }')"
	[ -n "$field" ] || fail "obake missing from $archive shadow"
	printf '%s' "$field"
}

rm -rf "$out"
mkdir -p "$out"

log "building default image (no OBKA_PASSWORD)"
MAKE_DISK=0 OBAKE_OUTDIR="$out/default" bash "$buildsh" "$board" virtual \
	>"$out/default-build.log" 2>&1
default_tar="$out/default/rootfs.tar"
[ -f "$default_tar" ] || fail "no default rootfs.tar"
default_pw="$(shadow_field "$default_tar")"
case "$default_pw" in
\*|!|!!) ;;
*) fail "default build should disable password login (shadow=$default_pw)" ;;
esac
if tar_cat "$default_tar" etc/ssh/sshd_config.d/obake-password.conf \
	>/dev/null 2>&1; then
	fail "default build must not install obake-password.conf"
fi
log "default build keeps password login disabled"

log "building image with OBKA_PASSWORD"
MAKE_DISK=1 OBKA_PASSWORD="$test_password" \
	OBAKE_OUTDIR="$out/password" bash "$buildsh" "$board" virtual \
	>"$out/password-build.log" 2>&1
pass_tar="$out/password/rootfs.tar"
disk="$out/password/disk-a.img"
[ -f "$disk" ] || fail "no disk image ($disk)"
[ -f "$pass_tar" ] || fail "no password rootfs.tar"
pass_pw="$(shadow_field "$pass_tar")"
case "$pass_pw" in
\$6\$*|\$5\$*|\$y\$*|\$ga\$*) ;;
*) fail "password build shadow is not a hash (shadow starts: ${pass_pw:0:4})" ;;
esac
dropin="$(tar_cat "$pass_tar" etc/ssh/sshd_config.d/obake-password.conf 2>/dev/null)" ||
	fail "password build missing obake-password.conf"
printf '%s\n' "$dropin" | grep -q '^PasswordAuthentication yes$' ||
	fail "obake-password.conf does not enable PasswordAuthentication"

printf '%s\n' "$test_password" >"$out/password.txt"
chmod 600 "$out/password.txt"
cat >"$out/askpass" <<EOF
#!/bin/sh
cat '$out/password.txt'
EOF
chmod 700 "$out/askpass"

efi_vars="$out/vars.fd"
cp "$OVMF_VARS" "$efi_vars"
log_file="$out/qemu.log"

log "booting (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
# shellcheck disable=SC2086
"$OBKA_QEMU_BIN" \
	$OBKA_QEMU_MACHINE_ARGS -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
	-m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
	$OBKA_QEMU_FW_ARGS \
	-drive if=pflash,format=raw,file="$efi_vars" \
	-drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
	-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
	-device virtio-net-pci,netdev=n0 \
	-nographic >"$log_file" 2>&1 &
qemu_pid=$!
trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT

ssh_pw() {
	# Prefer password auth; do not offer a key.
	DISPLAY= SSH_ASKPASS="$out/askpass" SSH_ASKPASS_REQUIRE=force \
		ssh -p "$ssh_port" \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null \
			-o LogLevel=ERROR \
			-o ConnectTimeout=3 \
			-o PreferredAuthentications=password \
			-o PubkeyAuthentication=no \
			-o NumberOfPasswordPrompts=1 \
			-o IdentitiesOnly=yes \
			obake@127.0.0.1 "$@"
}

log "waiting for SSH password login as obake"
ready=0
for _ in $(seq 1 "$boot_timeout"); do
	if ssh_pw true 2>/dev/null; then ready=1; break; fi
	sleep 3
done
if [ "$ready" != 1 ]; then
	port_state=closed
	(exec 3<>"/dev/tcp/127.0.0.1/$ssh_port") 2>/dev/null && port_state=open
	DISPLAY= SSH_ASKPASS="$out/askpass" SSH_ASKPASS_REQUIRE=force \
		ssh -vvv -p "$ssh_port" \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null \
			-o PreferredAuthentications=password \
			-o PubkeyAuthentication=no \
			-o NumberOfPasswordPrompts=1 \
			-o ConnectTimeout=5 \
			obake@127.0.0.1 true >"$out/ssh-debug.log" 2>&1 || true
	fail "could not log in over SSH with password (port $port_state); see $out/ssh-debug.log and $log_file"
fi

who="$(ssh_pw 'id -un' 2>/dev/null)" || fail "password SSH command failed"
[ "$who" = "obake" ] || fail "expected user obake, got: $who"

kill "$qemu_pid" 2>/dev/null || true
trap - EXIT
printf 'PASS: default password disabled; OBKA_PASSWORD enables SSH password login\n'
