#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/../.." && pwd)"

image="${OBKA_BUILD_IMAGE:-obake-build-env}"
platform="${OBKA_BUILD_PLATFORM:-linux/amd64}"

[ "$#" -ge 1 ] || { printf 'usage: run.sh <command> [args...]\n' >&2; exit 2; }

docker build --platform "$platform" -t "$image" "$here"

# Pass the KVM device through when the host provides it (Linux/WSL2 with nested
# virtualization) so the QEMU harnesses can use hardware acceleration.
run_args=(--rm --platform "$platform" -v "$project_root:/work" -w /work)
if [ -e /dev/kvm ]; then
  run_args+=(--device /dev/kvm)
fi

docker run "${run_args[@]}" "$image" "$@"
