#!/usr/bin/env bash
set -euo pipefail

# SSH credential verification. Builds a disk image with the obake user and an
# injected authorized key seed, boots it with a forwarded SSH port, and:
#   - logs in over SSH as the obake user with the seeded key;
#   - writes within the contract (/home/obake) successfully;
#   - cannot write to /etc or the read-only root;
#   - replaces its authorized key in place and proves the seed is retired;
#   - boots with the seeded host name, renames the host without sudo, and
#     proves the rename survives a slot switch.
#
# The image is built through the verification build wrapper (which uses the
# Buildroot build container when Docker is available) and booted under the
# host's QEMU.
#
# Usage: ssh-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

arch="${1:-native}"
board="$(obka_board "$arch")"
out="${OUT_BASE:-$image_root/_verify/$OBKA_ARCH/ssh}"
boot_timeout="${SSH_BOOT_TIMEOUT:-180}"
ssh_port="${SSH_TEST_PORT:-2222}"
seed_hostname="obake-ssh1"
new_hostname="obake-ssh2"

log() { printf '[ssh-test] %s\n' "$*" >&2; }
fail() { printf '[ssh-test] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "generating test key pair"
ssh-keygen -q -t ed25519 -N '' -f "$out/id"

log "building image"
MAKE_DISK=1 OBKA_SSH_AUTHORIZED_KEY="$out/id.pub" OBKA_HOSTNAME="$seed_hostname" \
	OBAKE_OUTDIR="$out/image" bash "$buildsh" "$board" virtual --update \
	>"$out/build.log" 2>&1

disk="$out/image/disk-a.img"
[ -f "$disk" ] || fail "no disk image ($disk)"

ssh_opts=(-p "$ssh_port" -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3
	-o PreferredAuthentications=publickey -o IdentitiesOnly=yes)
ssh_run_key() { # ssh_run_key <key> <remote-command...>
	local key="$1"
	shift
	ssh -i "$key" "${ssh_opts[@]}" obake@127.0.0.1 "$@"
}

qemu_pid=""
boot() { # boot <phase>
	local vars="$out/$1.fd"
	cp "$OVMF_VARS" "$vars"
	# shellcheck disable=SC2086
	"$OBKA_QEMU_BIN" \
		$OBKA_QEMU_MACHINE_ARGS -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
		-m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
		$OBKA_QEMU_FW_ARGS \
		-drive if=pflash,format=raw,file="$vars" \
		-drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
		-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
		-device virtio-net-pci,netdev=n0 \
		-nographic >"$out/$1.log" 2>&1 &
	qemu_pid=$!
	trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT
}

wait_ssh() { # wait_ssh <key>
	local key="$1" _
	log "waiting for sshd (key ${key##*/})"
	for _ in $(seq 1 "$boot_timeout"); do
		if ssh_run_key "$key" true 2>/dev/null; then return 0; fi
		sleep 3
	done
	ssh -vvv -i "$key" "${ssh_opts[@]}" -o ConnectTimeout=5 obake@127.0.0.1 true \
		>"$out/ssh-debug.log" 2>&1 || true
	fail "could not log in over SSH with ${key##*/}; see $out/ssh-debug.log"
}

stop_qemu() {
	local _
	for _ in $(seq 1 60); do
		kill -0 "$qemu_pid" 2>/dev/null || return 0
		sleep 1
	done
	kill "$qemu_pid" 2>/dev/null || true
	return 0
}

# --- Phase 1: contract, permissions, key replacement, slot switch -----------
boot phase1
wait_ssh "$out/id"

log "checking the directory contract over SSH"
home_out="$(ssh_run_key "$out/id" 'echo ok > /home/obake/contract-ok && echo HOME_WRITE_OK' 2>&1)" ||
	fail "user could not write within the contract: $home_out"
printf '%s\n' "$home_out" | grep -q HOME_WRITE_OK || fail "contract write failed"

if ssh_run_key "$out/id" 'touch /etc/obake-should-fail' 2>/dev/null; then
	fail "user was able to write to /etc"
fi
if ssh_run_key "$out/id" 'touch /obake-root-probe' 2>/dev/null; then
	fail "user was able to write to the read-only root"
fi

log "checking polkit-granted systemctl as obake"
if ! ssh_run_key "$out/id" 'systemctl restart obake-launcher.service' >/dev/null 2>&1; then
	fail "obake could not manage a unit via polkit without authentication"
fi

log "checking diagnostics access as obake"
if ! ssh_run_key "$out/id" 'dmesg >/dev/null 2>&1'; then
	fail "obake could not read the kernel log via dmesg"
fi
# A non-member of systemd-journal only sees its own messages; require an entry
# from a service the user does not own to prove full-journal access.
if ! ssh_run_key "$out/id" 'journalctl -b -u ssh.service --no-pager -n 1 2>/dev/null | grep -q .'; then
	fail "obake could not read the full system journal via journalctl"
fi

log "checking login accounting (last / wtmp) as obake"
# OpenSSH only writes wtmp when a PTY is allocated; force one with -tt.
if ! ssh -tt -i "$out/id" "${ssh_opts[@]}" obake@127.0.0.1 \
	'last 2>/dev/null | grep -q obake' >/dev/null 2>&1; then
	fail "last did not succeed or did not list the obake SSH session"
fi

log "checking lingering user bus via login shell (systemctl --user)"
if ! ssh_run_key "$out/id" 'bash -lc "systemctl --user status"' >/dev/null 2>&1; then
	fail "systemctl --user failed in a login shell (user-bus env missing?)"
fi

log "checking PAM login realtime limits (ulimit -r / -l)"
rtprio="$(ssh_run_key "$out/id" 'bash -lc "ulimit -r"')" ||
	fail "could not read ulimit -r in a login shell"
[ "$rtprio" = "95" ] ||
	fail "expected ulimit -r 95 in a login shell, got '$rtprio'"
memlock="$(ssh_run_key "$out/id" 'bash -lc "ulimit -l"')" ||
	fail "could not read ulimit -l in a login shell"
case "$memlock" in
unlimited | infinity | Unlimited | Infinity) ;;
*) fail "expected unlimited memlock in a login shell, got '$memlock'" ;;
esac

log "checking the seeded host name"
got_host="$(ssh_run_key "$out/id" 'hostname')"
[ "$got_host" = "$seed_hostname" ] ||
	fail "expected seeded host name $seed_hostname, got '$got_host'"

log "renaming the host without sudo (hostnamectl)"
ssh_run_key "$out/id" "hostnamectl set-hostname $new_hostname" >/dev/null 2>&1 ||
	fail "obake could not rename the host without sudo"
got_host="$(ssh_run_key "$out/id" 'hostname')"
[ "$got_host" = "$new_hostname" ] ||
	fail "host name did not change to $new_hostname (got '$got_host')"

log "replacing the authorized key in place (no sudo)"
ssh-keygen -q -t ed25519 -N '' -f "$out/id2"
ssh -i "$out/id" "${ssh_opts[@]}" obake@127.0.0.1 \
	'umask 077; cat > ~/.ssh/authorized_keys' <"$out/id2.pub" ||
	fail "could not write ~/.ssh/authorized_keys over SSH"
if ssh_run_key "$out/id" true 2>/dev/null; then
	fail "the seeded key still authenticates after replacement"
fi
ssh_run_key "$out/id2" true >/dev/null 2>&1 ||
	fail "the replacement key did not authenticate"
log "seeded key retired; replacement key works"

log "switching slots (obake-update rollback)"
ssh_run_key "$out/id2" 'obake-update rollback' >/dev/null 2>&1 ||
	fail "obake-update rollback failed"
ssh_run_key "$out/id2" 'systemctl poweroff' >/dev/null 2>&1 || true
stop_qemu

# --- Phase 2: the replacement key survives the slot switch ------------------
boot phase2
wait_ssh "$out/id2"
if ssh_run_key "$out/id" true 2>/dev/null; then
	fail "the retired seed key works again after a slot switch"
fi
log "replacement key survived the slot switch; seed still retired"
got_host="$(ssh_run_key "$out/id2" 'hostname')"
[ "$got_host" = "$new_hostname" ] ||
	fail "host name did not persist across the slot switch (got '$got_host')"
log "renamed host name survived the slot switch"
ssh_run_key "$out/id2" 'systemctl poweroff' >/dev/null 2>&1 || true
stop_qemu
trap - EXIT

printf 'PASS: SSH access, contract, key seeding/replacement, host name seeding/rename, slot persistence\n'
