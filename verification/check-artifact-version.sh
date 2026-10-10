#!/usr/bin/env bash
# Assert pinned-inputs.json image_version matches the staged VERSION stamp.
#
# Usage: check-artifact-version.sh <artifact-dir>
set -euo pipefail

dir="${1:?usage: check-artifact-version.sh <artifact-dir>}"
version_file="$dir/VERSION"
pinned="$dir/pinned-inputs.json"

[ -d "$dir" ] || {
	printf '[check-artifact-version] error: not a directory: %s\n' "$dir" >&2
	exit 2
}
[ -f "$version_file" ] || {
	printf '[check-artifact-version] error: missing %s\n' "$version_file" >&2
	exit 2
}
[ -f "$pinned" ] || {
	printf '[check-artifact-version] error: missing %s\n' "$pinned" >&2
	exit 2
}

version="$(tr -d '[:space:]' <"$version_file")"
pinned_version="$(
	python3 - "$pinned" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("image_version", ""))
PY
)"

if [ "$version" != "$pinned_version" ]; then
	printf '[check-artifact-version] FAIL: VERSION=%s pinned-inputs image_version=%s\n' \
		"$version" "$pinned_version" >&2
	exit 1
fi

printf '[check-artifact-version] OK: %s\n' "$version" >&2
