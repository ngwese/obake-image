#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/.." && pwd)"
layout="$project_root/os/partition-layout.json"
images_dir="${IMAGES_DIR:-$project_root/dist/os/amd64}"
active_slot="${ACTIVE_SLOT:-a}"
target_disk="${TARGET_DISK:-}"

log() { printf '[install] %s\n' "$*" >&2; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }

layout_rows() {
  python3 - "$layout" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for p in data["partitions"]:
    print(p["order"], p["role"], p["label"], p["typeGuid"], p["sizeMiB"], p.get("grow", False))
PY
}

layout_field() {
  python3 - "$layout" "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for p in data["partitions"]:
    if p["role"] == sys.argv[2]:
        print(p[sys.argv[3]])
        break
else:
    raise SystemExit(f"unknown role: {sys.argv[2]}")
PY
}

partdev() { printf '/dev/disk/by-partlabel/%s' "$1"; }

list_disks() {
  lsblk -dno NAME,SIZE,TYPE | awk '$3 == "disk" { print "/dev/" $1, $2 }'
}

select_disk() {
  if [ -n "$target_disk" ]; then
    printf '%s' "$target_disk"
    return
  fi
  log "available disks:"
  list_disks | sed 's/^/  /' >&2
  printf 'select destination disk: ' >&2
  read -r disk
  [ -b "$disk" ] || die "not a block device: $disk"
  printf 'DESTROY %s and install obake? [y/N] ' "$disk" >&2
  read -r answer
  case "$answer" in y | Y) ;; *) die "aborted" ;; esac
  printf '%s' "$disk"
}

partition_disk() {
  local disk="$1"
  log "partitioning $disk"
  sgdisk --zap-all "$disk" >/dev/null
  while read -r order role label guid size grow; do
    local end
    if [ "$grow" = "True" ]; then end="0"; else end="+${size}M"; fi
    sgdisk --new="${order}:0:${end}" \
      --typecode="${order}:${guid}" \
      --change-name="${order}:${label}" "$disk" >/dev/null
  done < <(layout_rows)
  partprobe "$disk" || true
  udevadm settle || true
}

format_partitions() {
  log "creating filesystems"
  mkfs.vfat -F32 -n "$(layout_field esp label)" "$(partdev "$(layout_field esp label)")" >/dev/null
  for role in root_a root_b persist user; do
    mkfs.ext4 -q -L "$(layout_field "$role" label)" "$(partdev "$(layout_field "$role" label)")"
  done
}

write_slot() {
  local slot="$1"
  local image="$images_dir/root-$slot.img"
  [ -f "$image" ] || die "missing slot image: $image"
  log "writing root slot $slot"
  dd if="$image" of="$(partdev "$(layout_field "root_$slot" label)")" bs=4M status=none conv=fsync
}

install_boot() {
  local esp="/mnt/obka-esp"
  mkdir -p "$esp"
  mount "$(partdev "$(layout_field esp label)")" "$esp"
  bootctl --esp-path="$esp" install >/dev/null
  mkdir -p "$esp/EFI/Linux"
  for slot in a b; do
    [ -f "$images_dir/obake-$slot.efi" ] || continue
    cp "$images_dir/obake-$slot.efi" "$esp/EFI/Linux/obake-$slot.efi"
  done
  cp "$images_dir/obake-$active_slot.efi" "$esp/EFI/Linux/obake-$active_slot+3+good.efi" 2>/dev/null || true
  umount "$esp"
}

seed_persist() {
  local persist="/mnt/obka-persist"
  mkdir -p "$persist"
  mount "$(partdev "$(layout_field persist label)")" "$persist"
  mkdir -p "$persist/etc" "$persist/var" "$persist/etc-overlay/upper" "$persist/etc-overlay/work"
  systemd-machine-id-setup --root="$persist" >/dev/null 2>&1 || true
  ssh-keygen -A -f "$persist" >/dev/null 2>&1 || true
  printf 'obake\n' >"$persist/etc/hostname"
  umount "$persist"
}

seed_user() {
  local user="/mnt/obka-user"
  mkdir -p "$user"
  mount "$(partdev "$(layout_field user label)")" "$user"
  mkdir -p "$user/home"
  umount "$user"
}

disk="$(select_disk)"
partition_disk "$disk"
format_partitions
write_slot a
write_slot b
install_boot
seed_persist
seed_user
sync
log "install complete"
printf 'OBKA_INSTALL_DONE\n'
