#!/usr/bin/env bash
# Pin Buildroot's host-rust / host-rust-bin to the same version as
# services/obake-ravenna/rust-toolchain.toml. Idempotent; safe to run on
# every image build after the Buildroot tree is unpacked.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
br_external="$(cd "$here/.." && pwd)"
src="${1:?usage: pin-rust.sh <buildroot-src>}"
want=1.99.1

bin_mk="$src/package/rust-bin/rust-bin.mk"
rust_mk="$src/package/rust/rust.mk"
bin_hash_src="$br_external/board/obake/patches/rust-bin/$want/rust-bin.hash"
rust_hash_src="$br_external/board/obake/patches/rust/$want/rust.hash"

[ -f "$bin_mk" ] || {
	printf '[pin-rust] error: missing %s\n' "$bin_mk" >&2
	exit 1
}
[ -f "$bin_hash_src" ] || {
	printf '[pin-rust] error: missing %s\n' "$bin_hash_src" >&2
	exit 1
}
[ -f "$rust_hash_src" ] || {
	printf '[pin-rust] error: missing %s\n' "$rust_hash_src" >&2
	exit 1
}

cur="$(sed -n 's/^RUST_BIN_VERSION = //p' "$bin_mk" | head -1)"
if [ "$cur" = "$want" ] &&
	grep -q "rust-$want-x86_64-unknown-linux-gnu.tar.xz" \
		"$src/package/rust-bin/rust-bin.hash" &&
	grep -q "rustc-$want-src.tar.xz" "$src/package/rust/rust.hash"; then
	printf '[pin-rust] host-rust-bin already %s\n' "$want" >&2
	exit 0
fi

printf '[pin-rust] pinning host-rust-bin %s -> %s\n' "${cur:-unknown}" "$want" >&2
sed -i "s/^RUST_BIN_VERSION = .*/RUST_BIN_VERSION = $want/" "$bin_mk"
sed -i "s/^RUST_VERSION = .*/RUST_VERSION = $want/" "$rust_mk"
cp -f "$bin_hash_src" "$src/package/rust-bin/rust-bin.hash"
cp -f "$rust_hash_src" "$src/package/rust/rust.hash"
