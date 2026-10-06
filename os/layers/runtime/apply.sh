#!/usr/bin/env bash
set -euo pipefail

# Runtime layer: Singularity CE built from source at a pinned version in the
# containerized build environment and staged for installation into the image.
# Distribution packages are not used because they are absent or too old.

rootfs="${1:?usage: runtime/apply.sh <rootfs> <arch> [board]}"
arch="${2:?}"
board="${3:-generic}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/../.." && pwd)"
manifest="$os_dir/manifest.json"

eval "$(python3 - "$manifest" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["singularity"]
print(f'staged={data["stagedRoot"]}')
print(f'version={data["version"]}')
PY
)"

# Overrides let a rebuild (e.g. an update bundle) ship a different pinned
# Singularity CE version than the one baked into the build environment.
staged="${OBKA_SINGULARITY_STAGE:-$staged}"
version="${OBKA_SINGULARITY_VERSION:-$version}"

if [ ! -x "$staged/usr/local/bin/singularity" ]; then
  printf '[runtime] error: staged Singularity CE not found at %s\n' "$staged" >&2
  printf '[runtime] build the build environment first: verification/build-env/run.sh true\n' >&2
  exit 1
fi

cp -a "$staged/." "$rootfs/"

install -d "$rootfs/etc/obake"
printf 'singularity=%s\nsource=pinned-source-build\n' "$version" >"$rootfs/etc/obake/singularity"

# A system-wide state directory used by the runtime.
install -d "$rootfs/var/lib/singularity"
