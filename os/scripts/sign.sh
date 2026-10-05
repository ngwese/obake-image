#!/usr/bin/env bash
set -euo pipefail

out="${1:?usage: sign.sh <outdir>}"

key="${OBKA_SIGNING_KEY:-}"
if [ -z "$key" ]; then
  printf '[sign] OBKA_SIGNING_KEY not set; writing checksums only\n' >&2
  ( cd "$out" && sha256sum ./*.img ./*.efi > SHA256SUMS )
  exit 0
fi

for artifact in "$out"/*.img "$out"/*.efi; do
  [ -f "$artifact" ] || continue
  openssl dgst -sha256 -sign "$key" -out "$artifact.sig" "$artifact"
done
printf '[sign] signed artifacts in %s\n' "$out" >&2
