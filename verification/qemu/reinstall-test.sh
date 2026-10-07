#!/usr/bin/env bash
set -euo pipefail

# Reinstall verification: install to a target, write a marker into the user
# partition, reinstall over the same disk, and assert the user partition was
# preserved.
#
# Usage: reinstall-test.sh [arch]

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../../.." && pwd)"
arch="${1:-native}"
out="${OUT_BASE:-$project_root/dist/verify/$OBKA_ARCH/reinstall}"
timeout_s="${INSTALL_TIMEOUT:-900}"
marker="obake preserve me"
arch_dir="$project_root/dist/os/$OBKA_ARCH"

log() { printf '[reinstall] %s\n' "$*" >&2; }
fail() { printf '[reinstall] FAIL: %s\n' "$*" >&2; exit 1; }

# Run a disk tool (sgdisk/debugfs) on the target. On a host without them the
# build container provides them.
cpath() { printf '%s' "$1" | sed "s#^$project_root#/work#"; }
disk_tool() {
	if command -v sgdisk >/dev/null 2>&1; then
		"$@"
	else
		local args=()
		local a
		for a in "$@"; do args+=("$(cpath "$a")"); done
		"$project_root/image/verification/build-env/run.sh" "${args[@]}"
	fi
}

mkdir -p "$out"
log "building installer image"
[ -f "$arch_dir/installer.img" ] || \
	( cd "$project_root/image/verification" && MAKE_INSTALLER=1 \
		INSTALLER_TARGET_DISK=/dev/vdb INSTALLER_PRESERVE_USER=1 \
		./build.sh "$arch" "$arch_dir" ) >"$out/build.log" 2>&1

installer="$arch_dir/installer.img"
target="$out/target.img"
rm -f "$target"
qemu-img create -f raw "$target" 8G >/dev/null

run_installer() { # run_installer <log>
	local logfile="$1" vars
	vars="$(mktemp)"
	cp "$OVMF_VARS" "$vars"
	set +e
	log "accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU smp=$OBKA_QEMU_SMP"
	# shellcheck disable=SC2086
	timeout "$timeout_s" "$OBKA_QEMU_BIN" \
		$OBKA_QEMU_MACHINE_ARGS -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
		-m "$OBKA_QEMU_MEM" -smp "$OBKA_QEMU_SMP" -no-reboot \
		$OBKA_QEMU_FW_ARGS \
		-drive if=pflash,format=raw,file="$vars" \
		-drive if=none,id=inst,format=raw,file="$installer","$OBKA_QEMU_DISK_OPTS" \
		-device virtio-blk-pci,drive=inst,bootindex=0 \
		-drive if=none,id=tgt,format=raw,file="$target","$OBKA_QEMU_DISK_OPTS" \
		-device virtio-blk-pci,drive=tgt,bootindex=1 \
		-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
		-nographic >"$logfile" 2>&1
	local rc=$?
	set -e
	rm -f "$vars"
	return $rc
}

user_part_offsets() {
	disk_tool sgdisk -i 5 "$target" |
		awk '/First sector/{s=$3} /Last sector/{e=$3} END{print s, e}'
}

inject_marker() {
	local part="$out/user-part.img" start end
	read -r start end < <(user_part_offsets)
	dd if="$target" of="$part" bs=512 skip="$start" count=$((end - start + 1)) status=none
	printf '%s\n' "$marker" >"$out/marker.txt"
	disk_tool debugfs -w -R "write $(cpath "$out/marker.txt") /home/obake-preserve-test" "$part" >/dev/null 2>&1 ||
		fail "could not write marker into user partition"
	dd if="$part" of="$target" bs=512 seek="$start" conv=notrunc status=none
}

check_marker() {
	local part="$out/user-part-check.img" start end got
	read -r start end < <(user_part_offsets)
	dd if="$target" of="$part" bs=512 skip="$start" count=$((end - start + 1)) status=none
	got="$(disk_tool debugfs -R "cat /home/obake-preserve-test" "$part" 2>/dev/null)"
	[ "$got" = "$marker" ] || fail "user partition marker not preserved (got '$got')"
}

log "first install (fresh)"
run_installer "$out/install1.log" || true
grep -qF "OBKA_INSTALL_DONE" "$out/install1.log" || fail "first install did not complete"

log "writing marker into the user partition"
inject_marker

log "second install (reinstall, preserving user data)"
run_installer "$out/install2.log" || true
grep -qF "OBKA_INSTALL_DONE" "$out/install2.log" || fail "reinstall did not complete"

check_marker
printf 'PASS: user partition preserved across reinstall\n'
