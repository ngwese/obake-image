#!/usr/bin/env bash
set -euo pipefail

# SSH directory-contract verification. Builds a disk image with the obake user
# and an injected authorized key, boots it with a forwarded SSH port, and:
#   - logs in over SSH as the obake user (proves SSH access and the key setup);
#   - writes within the contract (/home/obake) successfully;
#   - cannot write to /etc or the read-only root.
# Run inside the build environment.
#
# Usage: ssh-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../.." && pwd)"
arch="${1:-amd64}"
out="${OUT_BASE:-$project_root/dist/verify/$arch/ssh}"
boot_timeout="${SSH_BOOT_TIMEOUT:-180}"
ssh_port="${SSH_TEST_PORT:-2222}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

log() { printf '[ssh-test] %s\n' "$*" >&2; }
fail() { printf '[ssh-test] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "generating test key pair"
ssh-keygen -q -t ed25519 -N '' -f "$out/id"

log "building image"
MAKE_DISK=1 OBKA_SSH_AUTHORIZED_KEY="$out/id.pub" ARCH="$arch" \
  OUT="$out/image" "$project_root/os/build.sh" >"$out/build.log" 2>&1

disk="$out/image/disk-a.img"
efi_vars="$out/vars.fd"
cp "$ovmf_vars" "$efi_vars"
log_file="$out/qemu.log"

log "booting (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
qemu-system-x86_64 \
  -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
  -m 2048 -smp "$OBKA_QEMU_SMP" -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$efi_vars" \
  -drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
  -device virtio-net-pci,netdev=n0 \
  -nographic >"$log_file" 2>&1 &
qemu_pid=$!
trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT

ssh_opts=(-i "$out/id" -p "$ssh_port" -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3
  -o PreferredAuthentications=publickey -o IdentitiesOnly=yes)
ssh_run() { ssh "${ssh_opts[@]}" obake@127.0.0.1 "$@"; }

log "waiting for sshd"
ready=0
for _ in $(seq 1 "$boot_timeout"); do
  if ssh_run true 2>/dev/null; then ready=1; break; fi
  sleep 3
done
if [ "$ready" != 1 ]; then
  port_state=closed
  (exec 3<>"/dev/tcp/127.0.0.1/$ssh_port") 2>/dev/null && port_state=open
  ssh -vvv "${ssh_opts[@]}" -o ConnectTimeout=5 obake@127.0.0.1 true \
    >"$out/ssh-debug.log" 2>&1 || true
  fail "could not log in over SSH (port $port_state); see $out/ssh-debug.log and $log_file"
fi

log "checking the directory contract over SSH"
home_out="$(ssh_run 'echo ok > /home/obake/contract-ok && echo HOME_WRITE_OK' 2>&1)" ||
  fail "user could not write within the contract: $home_out"
printf '%s\n' "$home_out" | grep -q HOME_WRITE_OK || fail "contract write failed"

if ssh_run 'touch /etc/obake-should-fail' 2>/dev/null; then
  fail "user was able to write to /etc"
fi
if ssh_run 'touch /obake-root-probe' 2>/dev/null; then
  fail "user was able to write to the read-only root"
fi

log "checking polkit-granted systemctl as obake"
if ! ssh_run 'systemctl restart obake-launcher.service' >/dev/null 2>&1; then
  fail "obake could not manage a unit via polkit without authentication"
fi

# Power control should also be granted; the guest then powers off and QEMU
# exits (the run uses -no-reboot).
log "checking polkit-granted poweroff as obake"
ssh_run 'systemctl poweroff' >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$qemu_pid" 2>/dev/null; then
  kill "$qemu_pid" 2>/dev/null || true
  fail "obake could not power off the host via polkit"
fi
trap - EXIT
printf 'PASS: SSH access, directory contract, and polkit systemctl management\n'
