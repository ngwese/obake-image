#!/usr/bin/env bash
set -euo pipefail

# Developer VM helper: build the OS + installer with an SSH key baked into the
# install, install to a virtual disk under KVM, then boot it with SSH forwarded
# so you can log in and inspect the result.
#
# Run inside the build environment with the SSH port published, e.g.:
#   docker run --rm -it --device /dev/kvm -p 2222:2222 \
#     -v "$PWD:/work" -w /work obake-build-env verification/qemu/dev-vm.sh
#
# Then from the host:  ssh -i dist/dev/id -p 2222 obake@127.0.0.1
#
# Options:
#   -v, --verbose   log progress in detail (trace commands and stream build and
#                   install output to stderr as well as the log files)
#   -h, --help      show this help

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

verbose=0
usage() {
  cat >&2 <<'EOF'
Usage: dev-vm.sh [-v|--verbose] [-h|--help]

Builds obake with an SSH key baked into the install, installs to a virtual disk
under KVM, then boots it with SSH forwarded (port 2222 by default).

Run inside the build environment with the port published:
  docker run --rm -it --device /dev/kvm -p 2222:2222 \
    -v "$PWD:/work" -w /work obake-build-env verification/qemu/dev-vm.sh -v

Then from the host:
  ssh -i dist/dev/id -p 2222 obake@127.0.0.1

Options:
  -v, --verbose  log progress in detail (trace commands and stream build and
                 install output to stderr as well as the log files)
  -h, --help     show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  -v | --verbose) verbose=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'dev-vm.sh: unknown option: %s\n' "$1" >&2
    usage
    exit 2
    ;;
  esac
  shift
done

log() { printf '[dev-vm] %s\n' "$*" >&2; }
vlog() { [ "$verbose" = 1 ] && printf '[dev-vm] %s\n' "$*" >&2 || true; }
[ "$verbose" = 1 ] && set -x

# Run a command, capturing output to a log file (and streaming it when verbose).
run_capture() { # run_capture <logfile> <command...>
  local logfile="$1"
  shift
  if [ "$verbose" = 1 ]; then
    "$@" 2>&1 | tee "$logfile"
  else
    "$@" >"$logfile" 2>&1
  fi
}

project_root="$(cd "$here/../.." && pwd)"
arch="${ARCH:-amd64}"
work="${DEV_VM_DIR:-$project_root/dist/dev}"
port="${SSH_PORT:-2222}"
install_timeout="${INSTALL_TIMEOUT:-900}"
key="$work/id"
target="$work/target.img"
installer="$project_root/dist/os/$arch/installer.img"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

mkdir -p "$work"
vlog "work dir:    $work"
vlog "arch:        $arch"
vlog "ssh port:    $port"
vlog "accel:       $OBKA_QEMU_ACCEL_NAME (cpu=$OBKA_QEMU_CPU smp=$OBKA_QEMU_SMP)"

if [ ! -f "$key" ]; then
  log "generating SSH key $key"
  ssh-keygen -q -t ed25519 -N '' -f "$key"
fi

log "building OS artifacts and installer (accel=$OBKA_QEMU_ACCEL_NAME)"
vlog "OBKA_SSH_AUTHORIZED_KEY=$key.pub MAKE_INSTALLER=1 os/build.sh"
run_capture "$work/build.log" env OBKA_SSH_AUTHORIZED_KEY="$key.pub" \
  MAKE_INSTALLER=1 ARCH="$arch" "$project_root/os/build.sh"
vlog "installer:   $installer"

if [ ! -f "$target" ]; then
  log "creating target disk $target"
  qemu-img create -f raw "$target" 16G >/dev/null
fi

install_vars="$work/vars-install.fd"
cp "$ovmf_vars" "$install_vars"
log "installing to $target"
vlog "install OVMF vars: $install_vars"
run_capture "$work/install.log" timeout "$install_timeout" qemu-system-x86_64 \
  -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
  -m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$install_vars" \
  -drive if=none,id=inst,format=raw,file="$installer","$OBKA_QEMU_DISK_OPTS" \
  -device virtio-blk-pci,drive=inst,bootindex=0 \
  -drive if=none,id=tgt,format=raw,file="$target","$OBKA_QEMU_DISK_OPTS" \
  -device virtio-blk-pci,drive=tgt,bootindex=1 || true
if ! grep -qF "OBKA_INSTALL_DONE" "$work/install.log"; then
  log "install failed; see $work/install.log"
  exit 1
fi
vlog "install log: $work/install.log"

boot_vars="$work/vars.fd"
cp "$ovmf_vars" "$boot_vars"
log "installed; booting with SSH forwarded"
printf '\n[dev-vm]   ssh -i %s -p %s -o StrictHostKeyChecking=no obake@127.0.0.1\n\n' \
  "$key" "$port" >&2
exec qemu-system-x86_64 \
  -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
  -m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$boot_vars" \
  -drive file="$target",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
  -netdev "user,id=n0,hostfwd=tcp:0.0.0.0:${port}-:22" \
  -device virtio-net-pci,netdev=n0 \
  -nographic
