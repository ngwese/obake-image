#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../.." && pwd)"

image="${OBKA_BUILD_IMAGE:-obake-build-env}"
platform="${OBKA_BUILD_PLATFORM:-linux/amd64}"

[ "$#" -ge 1 ] || { printf 'usage: run.sh <command> [args...]\n' >&2; exit 2; }

docker build --platform "$platform" -t "$image" "$here"
docker run --rm --platform "$platform" \
  -v "$project_root:/work" \
  -w /work \
  "$image" "$@"
