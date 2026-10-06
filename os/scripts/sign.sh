#!/usr/bin/env bash
set -euo pipefail

# Emit a version stamp, checksums, and (when a signing key is configured)
# detached signatures over the image artifacts. The update system verifies the
# same signatures before writing a slot.

out="${1:?usage: sign.sh <outdir>}"
version="${VERSION:-0.0.0}"
arch="${ARCH:-amd64}"
slot="${SLOT:-a}"
key="${OBKA_SIGNING_KEY:-}"

[ -d "$out" ] || { printf '[sign] error: no such directory: %s\n' "$out" >&2; exit 1; }
cd "$out"

printf '%s\n' "$version" >VERSION

artifacts=()
for artifact in ./*.img ./*.efi ./*.tar; do
  [ -f "$artifact" ] || continue
  artifacts+=("$artifact")
done
[ "${#artifacts[@]}" -gt 0 ] || { printf '[sign] error: no artifacts in %s\n' "$out" >&2; exit 1; }

sha256sum "${artifacts[@]}" >SHA256SUMS

if [ -z "$key" ]; then
  printf '[sign] OBKA_SIGNING_KEY not set; wrote checksums only\n' >&2
else
  [ -f "$key" ] || { printf '[sign] error: signing key not found: %s\n' "$key" >&2; exit 1; }
  for artifact in "${artifacts[@]}"; do
    openssl dgst -sha256 -sign "$key" -out "$artifact.sig" "$artifact"
  done
  openssl dgst -sha256 -sign "$key" -out SHA256SUMS.sig SHA256SUMS
  printf '[sign] signed %s artifacts with %s\n' "${#artifacts[@]}" "$key" >&2
fi

cat >image-manifest.json <<EOF
{
  "version": "$version",
  "arch": "$arch",
  "slot": "$slot",
  "artifacts": $(printf '%s\n' "${artifacts[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
}
EOF
