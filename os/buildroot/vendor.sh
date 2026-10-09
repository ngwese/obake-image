#!/usr/bin/env bash
#
# Vendor the pinned build inputs for a release into vendor/, tracked with
# git-lfs.
#
#   vendor.sh
#
# Copies the pinned Buildroot release tarball and the complete Buildroot
# download cache (DL_DIR) from the build work directory into vendor/. build.sh
# then uses them directly, so a release builds without network access. Run this
# after a verified online build, then commit the result with git-lfs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$here/pins.json"
work="${OBAKE_WORK:-$here/../../_build/buildroot}"
dl="${DL_DIR:-$work/dl}"

pin() {
	python3 - "$pins" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    node = node[key]
print(node)
PY
}

br_release="$(pin buildroot.release)"
br_sha="$(pin buildroot.sha256)"
kver="$(pin kernel.version)"
ksha="$(pin kernel.sha256)"

src_tar="$work/buildroot-$br_release.tar.gz"
dst_tar="$here/vendor/buildroot-$br_release.tar.gz"
if [ -f "$src_tar" ]; then
	printf '%s  %s\n' "$br_sha" "$src_tar" | sha256sum -c -
elif [ -f "$dst_tar" ]; then
	# Already vendored; nothing to refresh.
	printf '%s  %s\n' "$br_sha" "$dst_tar" | sha256sum -c -
	src_tar=""
else
	printf 'error: Buildroot %s tarball missing\n' "$br_release" >&2
	exit 1
fi

[ -f "$dl/linux-$kver.tar.xz" ] || {
	printf 'error: %s missing; run a build first\n' "$dl/linux-$kver.tar.xz" >&2
	exit 1
}
printf '%s  %s\n' "$ksha" "$dl/linux-$kver.tar.xz" | sha256sum -c -

mkdir -p "$here/vendor/dl"
[ -n "$src_tar" ] && cp -f "$src_tar" "$here/vendor/"
rsync -rltD --no-owner --no-group --delete --exclude='.lock' \
	"$dl/" "$here/vendor/dl/"

printf '[vendor] vendored Buildroot %s and the download cache into %s\n' \
	"$br_release" "$here/vendor"
printf '[vendor] next: git add %s\n' "$here/vendor"
