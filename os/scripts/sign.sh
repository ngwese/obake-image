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

python3 - "$version" "$arch" "$slot" "$out" "${artifacts[@]}" <<'PY'
import json, os, sys

version, arch, slot, out = sys.argv[1:5]
manifest = {
    "version": version,
    "arch": arch,
    "slot": slot,
    "artifacts": sys.argv[5:],
}
pinned = os.path.join(out, "pinned-inputs.json")
if os.path.exists(pinned):
    with open(pinned) as f:
        manifest["pinned_inputs"] = json.load(f)
with open(os.path.join(out, "image-manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
PY
