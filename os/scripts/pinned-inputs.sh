#!/usr/bin/env bash
set -euo pipefail

# Emit the pinned-input set for a built board: the exact Buildroot release,
# kernel source, runtime versions, and EFI stub the image was built from.
#
# Usage: pinned-inputs.sh <outdir> <board> <arch> [target-dir]
#
# Writes <outdir>/pinned-inputs.json. When a built target directory is given the
# kernel version actually installed in the image is recorded too.

out="${1:?usage: pinned-inputs.sh <outdir> <board> <arch> [target-dir]}"
board="${2:?}"
arch="${3:?}"
target="${4:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extroot="$(cd "$here/.." && pwd)"
brroot="$extroot/buildroot"
pins="$brroot/pins.json"

[ -f "$pins" ] || { printf '[pinned-inputs] error: %s not found\n' "$pins" >&2; exit 1; }

sing_ver="$(sed -n 's/^SINGULARITY_VERSION = //p' "$brroot/package/singularity/singularity.mk")"
jack2_ver="$(sed -n 's/^OBAKE_JACK2_VERSION = //p' "$brroot/package/obake-jack2/obake-jack2.mk")"
[ -n "$sing_ver" ] || { printf '[pinned-inputs] error: no Singularity version\n' >&2; exit 1; }
[ -n "$jack2_ver" ] || { printf '[pinned-inputs] error: no jack2 version\n' >&2; exit 1; }

kernel_built=""
if [ -n "$target" ] && [ -f "$target/etc/obake/kernel" ]; then
	kernel_built="$(sed -n 's/^image=//p' "$target/etc/obake/kernel")"
fi

mkdir -p "$out"
python3 - "$pins" "$out/pinned-inputs.json" "$board" "$arch" \
	"$sing_ver" "$jack2_ver" "$kernel_built" "${OBAKE_IMAGE_VERSION:-0.0.0}" <<'PY'
import json, sys

pins_path, out_path, board, arch, sing, jack2, kernel_built, image_version = sys.argv[1:9]
pins = json.load(open(pins_path))

doc = {
    "board": board,
    "arch": arch,
    "image_version": image_version,
    "buildroot": {
        "release": pins["buildroot"]["release"],
        "sha256": pins["buildroot"]["sha256"],
    },
    "kernel": {
        "version": pins["kernel"]["version"],
        "sha256": pins["kernel"]["sha256"],
    },
    "runtime": {
        "singularity": sing,
        "jack2": jack2,
    },
    "efi_stub": {
        "systemd_version": pins["efi_stub"]["systemd_version"],
        "linuxaa64_sha256": pins["efi_stub"]["linuxaa64"]["sha256"],
    },
}
if kernel_built:
    doc["kernel"]["built"] = kernel_built

with open(out_path, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
PY

printf '[pinned-inputs] wrote %s/pinned-inputs.json (board=%s)\n' "$out" "$board" >&2
