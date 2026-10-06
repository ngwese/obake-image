#!/usr/bin/env bash
set -euo pipefail

# Build a signed RAUC update bundle for one slot from the built artifacts.
#
# Usage: make-bundle.sh <slot> <version> <rootimg> <uki> <outdir>
#
# Signing material comes from the environment:
#   RAUC_SIGNING_CERT  release certificate (PEM)
#   RAUC_SIGNING_KEY   release private key (PEM)

slot="${1:?usage: make-bundle.sh <slot> <version> <rootimg> <uki> <outdir>}"
version="${2:?usage: make-bundle.sh <slot> <version> <rootimg> <uki> <outdir>}"
rootimg="${3:?usage: make-bundle.sh <slot> <version> <rootimg> <uki> <outdir>}"
uki="${4:?usage: make-bundle.sh <slot> <version> <rootimg> <uki> <outdir>}"
outdir="${5:?usage: make-bundle.sh <slot> <version> <rootimg> <uki> <outdir>}"

cert="${RAUC_SIGNING_CERT:?RAUC_SIGNING_CERT must point to a certificate}"
key="${RAUC_SIGNING_KEY:?RAUC_SIGNING_KEY must point to a private key}"

for f in "$rootimg" "$uki" "$cert" "$key"; do
  [ -f "$f" ] || { printf '[bundle] error: missing %s\n' "$f" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$rootimg" "$work/root-$slot.img"
cp "$uki" "$work/obake-$slot.efi.img"

cat >"$work/manifest.raucm" <<EOF
[update]
compatible=obake
version=$version

[bundle]
format=verity

[image.rootfs]
filename=root-$slot.img

[image.boot]
filename=obake-$slot.efi.img
EOF

mkdir -p "$outdir"
out="$outdir/obake-$version-$slot.raucb"
rauc bundle --cert="$cert" --key="$key" "$work" "$out"
printf '%s\n' "$out"
