#!/usr/bin/env bash
set -euo pipefail

# Development update service: serve a directory of signed RAUC bundles to an
# embedded obake host on the same network. HTTP by default; set
# UPDATE_SERVER_TLS=1 for HTTPS with a generated self-signed certificate.
#
# Bundles are signature-verified on the target, so the transport is not the
# trust anchor. From a QEMU guest with user networking the build host is at
# 10.0.2.2.
#
# Usage: update-server.sh <bundle-dir> [port]
# Env:   UPDATE_SERVER_PORT, UPDATE_SERVER_BIND, UPDATE_SERVER_TLS

dir="${1:?usage: update-server.sh <bundle-dir> [port]}"
port="${2:-${UPDATE_SERVER_PORT:-8080}}"
bind="${UPDATE_SERVER_BIND:-0.0.0.0}"
tls="${UPDATE_SERVER_TLS:-0}"

dir="$(cd "$dir" && pwd)"

if [ "$tls" = "1" ]; then
  cert="$dir/tls.crt"
  key="$dir/tls.key"
  if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
    host="$(hostname)"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$key" -out "$cert" -days 30 -subj "/CN=$host"
  fi
  printf 'Serving https://%s:%s/ from %s\n' "$(hostname)" "$port" "$dir" >&2
  printf 'On the target set tls_cacert=%s (or tls_insecure=1 for dev).\n' "$cert" >&2
  exec python3 - "$port" "$bind" "$dir" "$cert" "$key" <<'PY'
import functools
import http.server
import ssl
import sys

port = int(sys.argv[1])
bind = sys.argv[2]
directory = sys.argv[3]
cert = sys.argv[4]
key = sys.argv[5]

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
httpd = http.server.ThreadingHTTPServer((bind, port), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PY
fi

printf 'Serving http://%s:%s/ from %s\n' "$(hostname)" "$port" "$dir" >&2
exec python3 -m http.server "$port" --bind "$bind" --directory "$dir"
