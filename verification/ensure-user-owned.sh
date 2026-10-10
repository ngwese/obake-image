#!/usr/bin/env bash
# Reclaim host-visible verification / developer-VM trees so the invoking user
# can remove them without elevated privileges.
#
# Usage: ensure-user-owned.sh <dir> [<dir>...]
#
# Tries a local chown first, then a root one-shot container (same idea as
# image/build/build.sh ensure_user_owned).
set -euo pipefail

if [ $# -lt 1 ]; then
	printf 'usage: %s <dir> [<dir>...]\n' "$0" >&2
	exit 2
fi

uid="$(id -u)"
gid="$(id -g)"
image="${OBKA_VERIFY_IMAGE:-obake-verify-env}"

reclaim() {
	local dir="$1"
	[ -e "$dir" ] || return 0
	# Nothing to do when every path under dir is already ours.
	if ! find "$dir" ! -user "$uid" -print -quit 2>/dev/null | grep -q .; then
		return 0
	fi
	if chown -R "$uid:$gid" "$dir" 2>/dev/null; then
		return 0
	fi
	if ! command -v docker >/dev/null 2>&1; then
		printf '[ensure-user-owned] error: cannot chown %s (no docker)\n' \
			"$dir" >&2
		return 1
	fi
	docker run --rm -v "$dir:/out" -u 0 "$image" \
		chown -R "$uid:$gid" /out >/dev/null
}

for d in "$@"; do
	reclaim "$d"
done
