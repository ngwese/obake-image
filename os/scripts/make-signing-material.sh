#!/usr/bin/env bash
set -euo pipefail

# Generate development signing material for RAUC bundles: a self-signed CA and a
# release certificate signed by it. Production signing keys are expected to live
# offline; this helper exists so the build and verification can be exercised
# end to end.
#
# Usage: make-signing-material.sh [outdir]

out="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.build/signing}"
mkdir -p "$out"

if [ ! -f "$out/ca.key" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$out/ca.key"
  openssl req -x509 -new -nodes -key "$out/ca.key" -sha256 -days 3650 \
    -subj "/CN=obake-ca" -out "$out/ca.cert.pem"
fi

if [ ! -f "$out/signing.key" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$out/signing.key"
  openssl req -new -key "$out/signing.key" -subj "/CN=obake-release" \
    -out "$out/signing.csr"
  openssl x509 -req -in "$out/signing.csr" \
    -CA "$out/ca.cert.pem" -CAkey "$out/ca.key" -CAcreateserial \
    -days 3650 -sha256 -out "$out/signing.cert.pem"
fi

printf '%s\n' "$out"
