#!/usr/bin/env bash
set -euo pipefail

# Build a staged Singularity CE tree (for the runtime layer) at a specific
# pinned version, by reusing the build-env Dockerfile's builder stage. Used to
# demonstrate shipping a newer runtime version via an update bundle.
#
# Usage: build-singularity-stage.sh <version> <sha256> <outdir>

version="${1:?usage: build-singularity-stage.sh <version> <sha256> <outdir>}"
sha256="${2:?usage: build-singularity-stage.sh <version> <sha256> <outdir>}"
outdir="${3:?usage: build-singularity-stage.sh <version> <sha256> <outdir>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/.." && pwd)"
image="obake-singularity-$version"

printf '[singularity-stage] building builder stage for %s\n' "$version" >&2
docker build --platform linux/amd64 --target singularity-build \
  --build-arg "SINGULARITY_VERSION=$version" \
  --build-arg "SINGULARITY_SHA256=$sha256" \
  -t "$image" "$project_root/verification/build-env" >&2

rm -rf "$outdir"
mkdir -p "$outdir"
printf '[singularity-stage] exporting to %s\n' "$outdir" >&2
docker run --rm -v "$outdir:/stage" "$image" \
  cp -a /opt/singularity-root/. /stage/
printf '%s\n' "$outdir"
