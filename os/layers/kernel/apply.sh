#!/usr/bin/env bash
set -euo pipefail

# Kernel layer: the PREEMPT_RT kernel package is installed by the base
# mmdebstrap step (see os/manifest.json). This overlay records the pinned kernel
# version and seeds a deterministic machine-id so systemd can start on a
# read-only root.

rootfs="${1:?usage: kernel/apply.sh <rootfs> <arch> [board]}"
arch="${2:?}"
board="${3:-generic}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/../.." && pwd)"
manifest="$os_dir/manifest.json"

kernel_image="$(python3 - "$manifest" "$arch" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data["kernel"]["image"][sys.argv[2]])
PY
)"

install -d "$rootfs/etc/obake"
cat >"$rootfs/etc/obake/kernel" <<EOF
flavor=rt
arch=$arch
image=$kernel_image
EOF

# Deterministic machine-id for the build artifact. A provisioned host gets a
# unique machine-id on the persist partition at install time.
machine_id="$(python3 - "$arch" <<'PY'
import sys, uuid
print(uuid.uuid5(uuid.NAMESPACE_URL, "obake-machine-id:" + sys.argv[1]))
PY
)"
printf '%s\n' "$machine_id" >"$rootfs/etc/machine-id"
: >"$rootfs/var/lib/dbus/machine-id" 2>/dev/null || true

[ -d "$here/files" ] && cp -a "$here/files/." "$rootfs/"

# Confirm the realtime kernel landed in the image.
if ! find "$rootfs/boot" -maxdepth 1 -name 'vmlinuz-*-rt-*' -print -quit | grep -q .; then
  printf '[kernel] error: no realtime kernel found in %s/boot\n' "$rootfs" >&2
  exit 1
fi
