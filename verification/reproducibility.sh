#!/usr/bin/env bash
set -euo pipefail

# Build the x86_64 image and record digests of the artifacts expected to be
# equivalent across development hosts. Run on each host; task 1.2c compares the
# per-platform records.
#
# Usage: reproducibility.sh <platform-label>   (e.g. wsl-x86_64, macos-arm64)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/.." && pwd)"
platform="${1:?usage: reproducibility.sh <platform-label>}"

"$project_root/os/build.sh"

mkdir -p "$here/reproducibility"
out="$here/reproducibility/$platform.sha256"
(
  cd "$project_root/dist/os/amd64"
  sha256sum root-a.tar root-b.tar obake-a.efi obake-b.efi
) >"$out"
cat "$out"
