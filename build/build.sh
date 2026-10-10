#!/usr/bin/env bash
# Build an obake Buildroot image and stage its artifacts.
#
# Usage:
#   build.sh <board> [profile] [--] [make-args...]
#   build.sh --print-dir <board> [profile]
#
#   board     generic-aarch64 | generic-x86_64 | qdl | rk35xx
#   profile   default (physical board) | virtual (emulation/verification);
#             defaults to default when omitted
#
# The target architecture follows from the board. Artifacts stage under
# image/_out/os/<board>/<profile>/<version>-<shortsha>[-dirty]/ override with
# OBAKE_OUTDIR. Build knobs (VERIFY*, BREAK, MAKE_DISK, MAKE_INSTALLER,
# IMAGE_TAG, RAUC_SIGNING_*, OBKA_SSH_AUTHORIZED_KEY, OBKA_PASSWORD, ...) are
# forwarded; an explicit setting wins over the board profile.
#
# On a host with Docker the build runs in the native build container as the
# invoking user. On a Linux host without Docker the Buildroot build runs
# directly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_root="$(cd "$here/.." && pwd)"
project_root="$(cd "$here/../.." && pwd)"

usage() {
	printf 'usage: %s [--print-dir] <board> [profile] [--] [make-args...]\n' "$0" >&2
	printf 'boards: generic-aarch64 generic-x86_64 qdl rk35xx\n' >&2
	printf 'profiles: default virtual\n' >&2
	exit 2
}

print_dir=0
if [ "${1:-}" = "--print-dir" ]; then
	print_dir=1
	shift
fi

[ $# -ge 1 ] || usage
board="$1"
shift

profile="default"
make_args=()
if [ $# -gt 0 ]; then
	case "$1" in
	--)
		shift
		make_args=("$@")
		;;
	default | virtual)
		profile="$1"
		shift
		if [ "${1:-}" = "--" ]; then
			shift
		fi
		make_args=("$@")
		;;
	*)
		# Remaining tokens are make args (e.g. -jN, clean).
		make_args=("$@")
		;;
	esac
fi

board_config="$image_root/os/buildroot/configs/obake-$board.config"
if [ ! -f "$board_config" ]; then
	printf '[build] error: unknown board %s\n' "$board" >&2
	usage
fi
case "$profile" in
default | virtual) ;;
*)
	printf '[build] error: unknown profile %s (supported: default virtual)\n' \
		"$profile" >&2
	exit 2
	;;
esac

artifact_dir() {
	local version sha dirty
	version="$(tr -d '[:space:]' <"$image_root/os/buildroot/VERSION")"
	sha="$("$image_root/os/scripts/image-git-rev.sh" sha)"
	dirty="$("$image_root/os/scripts/image-git-rev.sh" dirty)"
	printf '%s/_out/os/%s/%s/%s-%s%s' \
		"$image_root" "$board" "$profile" "$version" "$sha" "$dirty"
}

out="${OBAKE_OUTDIR:-$(artifact_dir)}"

if [ "$print_dir" = 1 ]; then
	printf '%s\n' "$out"
	exit 0
fi

export OBAKE_PROFILE="$profile"
export OBAKE_BOARD="$board"

stage_images() { # stage_images <src-images-dir>
	local src="$1" f
	rm -rf "$out"
	mkdir -p "$out"
	# Stage only produced top-level artifacts; skip Buildroot scratch dirs.
	for f in "$src"/*; do
		[ -e "$f" ] || continue
		[ -f "$f" ] || continue
		cp -a "$f" "$out/"
	done
}

print_artifacts() {
	local f
	printf 'artifact: %s\n' "$out"
	for f in "$out"/*; do
		[ -f "$f" ] || continue
		printf 'artifact: %s\n' "$f"
	done
}

ensure_user_owned() {
	local uid gid
	uid="$(id -u)"
	gid="$(id -g)"
	if [ -d "$out" ] && [ "$(stat -c '%u' "$out" 2>/dev/null || stat -f '%u' "$out")" != "$uid" ]; then
		if chown -R "$uid:$gid" "$out" 2>/dev/null; then
			return
		fi
		# Last resort when docker cp left root-owned files.
		if command -v docker >/dev/null 2>&1; then
			docker run --rm -v "$out:/out" -u 0 \
				"${OBKA_BUILD_IMAGE:-obake-buildroot-env}" \
				chown -R "$uid:$gid" /out >/dev/null
		fi
	fi
}

if command -v docker >/dev/null 2>&1; then
	work_in_container="${OBAKE_WORK:-/cache/buildroot}"
	volume="${OBKA_BUILD_VOLUME:-obake-buildroot-cache}"
	image="${OBKA_BUILD_IMAGE:-obake-buildroot-env}"
	# Verification uses small disk images so they can be staged on a laptop; the
	# release build uses the real partition-layout.json. Use the container path.
	export LAYOUT="${LAYOUT:-/work/image/os/partition-layout.verify.json}"
	# Resolve host paths to absolute form, then rewrite the repo prefix to the
	# container mount (/work). Relative paths (as in the docs) must not be left
	# relative: post-image runs with Buildroot's cwd, not the repo root.
	for v in RAUC_SIGNING_CERT RAUC_SIGNING_KEY RAUC_KEYRING VERIFY_UPDATE_BUNDLE \
		VERIFY_INTEGRATION_GOOD VERIFY_INTEGRATION_BAD OBKA_SSH_AUTHORIZED_KEY LAYOUT; do
		val="${!v:-}"
		[ -n "$val" ] || continue
		case "$val" in
		/*) ;;
		*) val="$(pwd)/$val" ;;
		esac
		val="$(realpath -m -- "$val")"
		export "$v=$(printf '%s' "$val" | sed "s#^$project_root#/work#")"
	done
	"$here/build-env/run.sh" bash image/os/buildroot/build.sh "$board" \
		${make_args[@]+"${make_args[@]}"}
	# Stage only top-level artifact files (skip .installer/.disk-work/.initramfs
	# and other scratch directories) straight into the host output directory.
	rm -rf "$out"
	mkdir -p "$out"
	docker run --rm --user "$(id -u):$(id -g)" \
		-v "$volume":/cache -v "$out":/out \
		-e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
		"$image" bash -c "
			set -e
			cd $work_in_container/output/$board/images
			for f in *; do
				[ -f \"\$f\" ] || continue
				cp -a \"\$f\" /out/
			done
		"
	# Drop large derived images from the cache tree; they are regenerated each
	# build and would otherwise accumulate in the build volume.
	docker run --rm -v "$volume":/cache "$image" sh -c \
		"rm -rf $work_in_container/output/$board/images/disk-*.img \
			$work_in_container/output/$board/images/.disk-work \
			$work_in_container/output/$board/images/.installer \
			$work_in_container/output/$board/images/.initramfs" \
		>/dev/null 2>&1 || true
	ensure_user_owned
else
	export LAYOUT="${LAYOUT:-$image_root/os/partition-layout.verify.json}"
	work="${OBAKE_WORK:-$image_root/_build/buildroot}"
	OBAKE_WORK="$work" DL_DIR="${DL_DIR:-$image_root/os/buildroot/vendor/dl}" \
		bash "$image_root/os/buildroot/build.sh" "$board" \
		${make_args[@]+"${make_args[@]}"}
	stage_images "$work/output/$board/images"
fi

print_artifacts
