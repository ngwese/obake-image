#!/usr/bin/env bash
set -euo pipefail

# Interactive installer verification: boot the installer with no preselected
# disk, drive the serial console to select the target disk and confirm the
# destructive action, and assert the install completes. Run inside the build
# environment.
#
# Usage: install-interactive-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../.." && pwd)"
arch="${1:-amd64}"
out="${OUT_BASE:-$project_root/dist/verify/$arch/install-interactive}"
timeout_s="${INSTALL_TIMEOUT:-900}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

mkdir -p "$out"
printf '[install-interactive] building installer image\n'
INSTALLER_TARGET_DISK=interactive INSTALLER_PRESERVE_USER=1 MAKE_INSTALLER=1 \
  ARCH="$arch" OUT="$out/artifacts" "$project_root/os/build.sh" \
  >"$out/build.log" 2>&1

installer="$out/artifacts/installer.img"
target="$out/target.img"
rm -f "$target"
qemu-img create -f raw "$target" 16G >/dev/null

python3 - "$installer" "$target" "$ovmf_code" "$ovmf_vars" "$out/serial.log" \
  "$timeout_s" <<'PY'
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time

installer, target, ovmf_code, ovmf_vars, log_path, timeout_s = sys.argv[1:7]
timeout_s = int(timeout_s)
vars_file = tempfile.NamedTemporaryFile(delete=False).name
shutil.copy(ovmf_vars, vars_file)

accel = os.environ.get("OBKA_QEMU_ACCEL_NAME", "tcg")
cpu = os.environ.get("OBKA_QEMU_CPU", "max")
smp = os.environ.get("OBKA_QEMU_SMP", "cores=4,threads=1,sockets=1")
disk_opts = os.environ.get("OBKA_QEMU_DISK_OPTS", "cache=none,aio=threads")
cmd = [
    "qemu-system-x86_64", "-machine", "q35", "-accel", accel, "-cpu", cpu,
    "-m", "2048", "-smp", smp,
    "-no-reboot",
    "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
    "-drive", f"if=pflash,format=raw,file={vars_file}",
    "-drive", f"if=none,id=inst,format=raw,file={installer},{disk_opts}",
    "-device", "virtio-blk-pci,drive=inst,bootindex=0",
    "-drive", f"if=none,id=tgt,format=raw,file={target},{disk_opts}",
    "-device", "virtio-blk-pci,drive=tgt,bootindex=1",
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
