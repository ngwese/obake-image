#!/usr/bin/env bash
#
# Headless checks for kernel-config-rev.sh. Builds a temporary image-shaped
# git repository and does not touch the real image tree.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/kernel-config-rev.sh"
board=demo

export GIT_AUTHOR_NAME=obake-test
export GIT_AUTHOR_EMAIL=obake-test@example.com
export GIT_COMMITTER_NAME=obake-test
export GIT_COMMITTER_EMAIL=obake-test@example.com

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/image"
shallow="$tmp/shallow"
nogit="$tmp/nogit"

fail() {
	printf 'kernel-config-rev-test: %s\n' "$1" >&2
	exit 1
}

rev_of() {
	OBAKE_IMAGE_ROOT="$1" "$helper" "$board"
}

expect() {
	local got="$1" want="$2" label="$3"
	[ "$got" = "$want" ] || fail "$label: expected $want, got $got"
}

write_tree() {
	local foo="$1" comment="${2:-}" localver="${3:-}" pin="${4:-7.2.9}"
	mkdir -p \
		"$root/os/buildroot/board/obake/$board" \
		"$root/os/buildroot/configs"
	{
		printf 'CONFIG_FOO=%s\n' "$foo"
		if [ -n "$comment" ]; then
			printf '%s\n' "$comment"
		fi
	} >"$root/os/buildroot/board/obake/linux-realtime.fragment"
	printf 'CONFIG_BAR=y\n' >"$root/os/buildroot/board/obake/linux-obake.fragment"
	{
		printf 'CONFIG_BAZ=y\n'
		if [ -n "$localver" ]; then
			printf 'CONFIG_LOCALVERSION="%s"\n' "$localver"
		fi
	} >"$root/os/buildroot/board/obake/$board/linux.config"
	cat >"$root/os/buildroot/configs/obake_base.config" <<EOF
# pin comment
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="${pin}"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="fragments"
EOF
	printf 'BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y\n' \
		>"$root/os/buildroot/configs/obake-$board.config"
}

commit_tree() {
	git -C "$root" add -A
	git -C "$root" commit -q -m "$1"
}

mkdir -p "$root"
git -C "$root" init -q
write_tree y
commit_tree 'config 1'
expect "$(rev_of "$root")" "-1-${board}" 'first hash'

write_tree n
commit_tree 'config 2'
expect "$(rev_of "$root")" "-2-${board}" 'second hash'

write_tree y
commit_tree 'restore config 1'
expect "$(rev_of "$root")" "-1-${board}" 'reverted hash'

write_tree n
before="$(git -C "$root" status --porcelain)"
expect "$(rev_of "$root")" "-2-${board}" 'dirty known hash'
after="$(git -C "$root" status --porcelain)"
[ "$before" = "$after" ] || fail 'helper modified the repo on a known dirty hash'

write_tree m
before="$(git -C "$root" status --porcelain)"
expect "$(rev_of "$root")" "-3-${board}" 'dirty unseen hash'
after="$(git -C "$root" status --porcelain)"
[ "$before" = "$after" ] || fail 'helper modified the repo on an unseen dirty hash'

write_tree y '# comment only'
commit_tree 'comment only'
expect "$(rev_of "$root")" "-1-${board}" 'comment-only edit'

write_tree y '' '-nope'
expect "$(rev_of "$root")" "-1-${board}" 'CONFIG_LOCALVERSION edit'

write_tree y '' '' '9.9.9'
expect "$(rev_of "$root")" "-1-${board}" 'kernel source-pin edit'

git -c protocol.file.allow=always clone -q --depth 1 "file://${root}" "$shallow"
if rev_of "$shallow" >/dev/null 2>&1; then
	fail 'shallow clone should fail'
fi

mkdir -p "$nogit"
expect "$(rev_of "$nogit")" "-0-${board}" 'missing git metadata'

printf 'kernel-config-rev-test: ok\n'
