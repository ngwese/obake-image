#!/usr/bin/env bash
set -euo pipefail

# Verify a detached signature over an image artifact against a public key.
# Exits non-zero if the artifact is missing, the signature is malformed, or the
# signature does not match.
#
# Usage: verify-signature.sh <public-key.pem> <artifact> [signature]

pub="${1:?usage: verify-signature.sh <public-key.pem> <artifact> [signature]}"
artifact="${2:?usage: verify-signature.sh <public-key.pem> <artifact> [signature]}"
sig="${3:-${artifact}.sig}"

[ -f "$pub" ] || { printf '[verify] error: public key not found: %s\n' "$pub" >&2; exit 2; }
[ -f "$artifact" ] || { printf '[verify] error: artifact not found: %s\n' "$artifact" >&2; exit 2; }
[ -f "$sig" ] || { printf '[verify] error: signature not found: %s\n' "$sig" >&2; exit 2; }

if openssl dgst -sha256 -verify "$pub" -signature "$sig" "$artifact" >/dev/null 2>&1; then
  printf '[verify] OK: %s\n' "$artifact"
else
  printf '[verify] FAIL: signature does not match %s\n' "$artifact" >&2
  exit 1
fi
