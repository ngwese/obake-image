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
pipewire_ver="$(sed -n 's/^OBAKE_PIPEWIRE_VERSION = //p' "$brroot/package/obake-pipewire/obake-pipewire.mk")"
wireplumber_ver="$(sed -n 's/^OBAKE_WIREPLUMBER_VERSION = //p' "$brroot/package/obake-wireplumber/obake-wireplumber.mk")"
[ -n "$sing_ver" ] || { printf '[pinned-inputs] error: no Singularity version\n' >&2; exit 1; }
[ -n "$pipewire_ver" ] || { printf '[pinned-inputs] error: no pipewire version\n' >&2; exit 1; }
[ -n "$wireplumber_ver" ] || { printf '[pinned-inputs] error: no wireplumber version\n' >&2; exit 1; }

kernel_built=""
if [ -n "$target" ] && [ -f "$target/etc/obake/kernel" ]; then
	kernel_built="$(sed -n 's/^image=//p' "$target/etc/obake/kernel")"
fi

# Same resolution as post-build/post-image: override, baked rootfs, VERSION file.
if [ -n "${OBAKE_IMAGE_VERSION:-}" ]; then
	image_version="$OBAKE_IMAGE_VERSION"
elif [ -n "$target" ] && [ -f "$target/etc/obake/image-version" ]; then
	image_version="$(tr -d '[:space:]' <"$target/etc/obake/image-version")"
elif [ -f "$brroot/VERSION" ]; then
	image_version="$(tr -d '[:space:]' <"$brroot/VERSION")"
else
	image_version="0.0.0"
fi
[ -n "$image_version" ] || image_version="0.0.0"

mkdir -p "$out"
python3 - "$pins" "$out/pinned-inputs.json" "$board" "$arch" \
	"$sing_ver" "$pipewire_ver" "$wireplumber_ver" "$kernel_built" \
	"$image_version" <<'PY'
import json, sys

(pins_path, out_path, board, arch, sing, pipewire, wireplumber,
 kernel_built, image_version) = sys.argv[1:10]
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
        "pipewire": pipewire,
        "singularity": sing,
        "wireplumber": wireplumber,
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
