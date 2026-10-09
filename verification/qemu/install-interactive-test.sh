#!/usr/bin/env bash
set -euo pipefail

# Interactive installer verification: boot the installer with no preselected
# disk, drive the serial console to select the target disk and confirm the
# destructive action, and assert the install completes.
#
# Usage: install-interactive-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

arch="${1:-native}"
board="$(obka_board "$arch")"
out="${OUT_BASE:-$image_root/_verify/$OBKA_ARCH/install-interactive}"
timeout_s="${INSTALL_TIMEOUT:-900}"
arch_dir="$(obka_arch_dir "$arch")"

mkdir -p "$out"
printf '[install-interactive] building installer image\n'
[ -f "$arch_dir/installer-serial.img" ] || \
	MAKE_INSTALLER=1 CONSOLE=serial \
		INSTALLER_TARGET_DISK=interactive \
		bash "$buildsh" "$board" virtual >"$out/build.log" 2>&1

installer="$arch_dir/installer-serial.img"
[ -f "$installer" ] || { printf 'missing installer image: %s\n' "$installer" >&2; exit 2; }
target="$out/target.img"
rm -f "$target"
qemu-img create -f raw "$target" 8G >/dev/null

python3 - "$installer" "$target" "$out/serial.log" "$timeout_s" <<'PY'
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time

installer, target, log_path, timeout_s = sys.argv[1:5]
timeout_s = int(timeout_s)
vars_file = tempfile.NamedTemporaryFile(delete=False).name
shutil.copy(os.environ["OVMF_VARS"], vars_file)

qemu_bin = os.environ.get("OBKA_QEMU_BIN", "qemu-system-aarch64")
machine = os.environ.get("OBKA_QEMU_MACHINE_ARGS", "-machine virt").split()
fw = os.environ.get("OBKA_QEMU_FW_ARGS", "").split()
accel = os.environ.get("OBKA_QEMU_ACCEL_NAME", "tcg")
cpu = os.environ.get("OBKA_QEMU_CPU", "max")
smp = os.environ.get("OBKA_QEMU_SMP", "cores=4,threads=1,sockets=1")
disk_opts = os.environ.get("OBKA_QEMU_DISK_OPTS", "cache=none,aio=threads")
cmd = [
    qemu_bin, *machine, "-accel", accel, "-cpu", cpu,
    "-m", "2048", "-smp", smp, "-no-reboot",
    *fw,
    "-drive", f"if=pflash,format=raw,file={vars_file}",
    "-drive", f"if=none,id=inst,format=raw,file={installer},{disk_opts}",
    "-device", "virtio-blk-pci,drive=inst,bootindex=0",
    "-drive", f"if=none,id=tgt,format=raw,file={target},{disk_opts}",
    "-device", "virtio-blk-pci,drive=tgt,bootindex=1",
    "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
    "-nographic",
]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT)
buf = bytearray()


def wait_for(token, timeout):
    deadline = time.time() + timeout
    token = token.encode()
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], 1)
        if ready:
            chunk = os.read(proc.stdout.fileno(), 4096)
            if not chunk:
                if proc.poll() is not None:
                    return token in buf
                continue
            buf.extend(chunk)
            if token in buf:
                return True
    return token in buf


def send(data):
    proc.stdin.write(data)
    proc.stdin.flush()


ok = False
try:
    if not wait_for("select destination disk:", timeout_s):
        raise SystemExit("no disk selection prompt")
    send(b"/dev/vdb\n")
    if not wait_for("DESTROY", 60):
        raise SystemExit("no destructive-action confirmation prompt")
    send(b"y\n")
    ok = wait_for("OBKA_INSTALL_DONE", timeout_s)
    if ok:
        # Interactive media waits for Enter before poweroff.
        if not wait_for("Press Enter to shut down", 60):
            raise SystemExit("no post-install shutdown prompt")
        send(b"\n")
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
finally:
    with open(log_path, "wb") as fh:
        fh.write(buf)
    if os.path.exists(vars_file):
        os.unlink(vars_file)

if ok:
    print("PASS: interactive selection and confirmation completed install")
    sys.exit(0)
print("FAIL: interactive install did not complete; see", log_path)
sys.exit(1)
PY
