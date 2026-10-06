#!/usr/bin/env bash
set -euo pipefail

# Assemble a bootable raw disk image from the built artifacts without mounting,
# so it works in a container without CAP_SYS_ADMIN. The disk uses the shared
# partition layout and carries systemd-boot plus the per-slot UKI on the ESP.
#
# Usage: make-disk.sh <slot> <arch> <outdir>

slot="${1:?usage: make-disk.sh <slot> <arch> <outdir>}"
arch="${2:?usage: make-disk.sh <slot> <arch> <outdir>}"
out="${3:?usage: make-disk.sh <slot> <arch> <outdir>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/.." && pwd)"
layout="$os_dir/partition-layout.json"
project_root="$(cd "$os_dir/.." && pwd)"

user_mib="${USER_SIZE_MIB:-8192}"
disk="$out/disk-$slot.img"
work="$project_root/.build/os/$arch-$slot/disk"
sector=512

log() { printf '[disk] %s\n' "$*" >&2; }
die() { printf '[disk] error: %s\n' "$*" >&2; exit 1; }

# Emit: order role label guid sizeMiB grow
mapfile -t parts < <(python3 - "$layout" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for p in data["partitions"]:
    print(p["order"], p["role"], p["label"], p["typeGuid"], p["sizeMiB"], str(p.get("grow", False)).lower())
PY
)

fixed_mib=0
for line in "${parts[@]}"; do
  read -r _ _ _ _ size grow <<<"$line"
  [ "$grow" = "true" ] && continue
  fixed_mib=$(( fixed_mib + size ))
done
total_mib=$(( fixed_mib + user_mib ))
total_sectors=$(( total_mib * 2048 ))
last_usable=$(( total_sectors - 34 )) # leave room for the backup GPT

rm -rf "$work"
mkdir -p "$work" "$out"
log "creating ${total_mib}MiB disk $disk"
rm -f "$disk"
truncate -s "${total_mib}M" "$disk"

sgdisk_args=(--zap-all)
start=2048 # 1 MiB alignment
declare -A part_start part_end part_size
for line in "${parts[@]}"; do
  read -r order role label guid size grow <<<"$line"
  if [ "$grow" = "true" ]; then
    end="$last_usable"
  else
    end=$(( start + size * 2048 - 1 ))
  fi
  sgdisk_args+=(--new="${order}:${start}:${end}"
    --typecode="${order}:${guid}"
    --change-name="${order}:${label}")
  part_start["$role"]=$start
  part_end["$role"]=$end
  part_size["$role"]=$(( (end - start + 1) / 2048 ))
  if [ "$grow" != "true" ]; then
    start=$(( end + 1 ))
  fi
done
sgdisk "${sgdisk_args[@]}" "$disk" >/dev/null

dd_at() { # dd_at <image> <role>
  local image="$1" role="$2" off
  off=$(( part_start["$role"] * sector ))
  dd if="$image" of="$disk" bs="$sector" seek="${part_start[$role]}" conv=notrunc status=none
  log "wrote ${image##*/} -> ${part_start[$role]} (${part_size[$role]}MiB)"
}

# --- ESP: systemd-boot, loader config, and the slot UKI ---------------------
esp_mib="${part_size[esp]}"
esp_img="$work/esp.img"
truncate -s "${esp_mib}M" "$esp_img"
mkfs.vfat -F32 -n "$(python3 - "$layout" esp label <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for p in data["partitions"]:
    if p["role"] == sys.argv[2]:
        print(p["label"])
PY
)" "$esp_img" >/dev/null

if [ "$arch" = "arm64" ]; then boot_dst="BOOTAA64.EFI"
else boot_dst="BOOTX64.EFI"; fi

mmd -i "$esp_img" ::/EFI ::/EFI/BOOT ::/EFI/Linux

for s in a b; do
  uki="$out/obake-$s.efi"
  [ -f "$uki" ] || continue
  mcopy -i "$esp_img" "$uki" "::/EFI/Linux/obake-$s.efi"
done
[ -f "$out/obake-$slot.efi" ] || die "missing UKI for active slot $slot"

# Firmware fallback: the active slot's UKI boots directly.
mcopy -i "$esp_img" "$out/obake-$slot.efi" "::/EFI/BOOT/$boot_dst"
dd_at "$esp_img" esp

# --- Root slots: write the built filesystem images --------------------------
for s in a b; do
  img="$out/root-$s.img"
  [ -f "$img" ] || img="$out/root-$slot.img"
  [ -f "$img" ] || die "missing root filesystem image for slot $s"
  dd_at "$img" "root_$s"
done

# --- Persist and user: empty but correctly labeled filesystems --------------
tmp="$work/empty.img"
for role in persist user; do
  bytes=$(( (part_end["$role"] - part_start["$role"] + 1) * sector ))
  rm -f "$tmp"
  truncate -s "$bytes" "$tmp"
  label="$(python3 - "$layout" "$role" label <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for p in data["partitions"]:
    if p["role"] == sys.argv[2]:
        print(p["label"])
PY
)"
  mke2fs -q -t ext4 -L "$label" "$tmp"
  dd_at "$tmp" "$role"
done

log "disk image ready: $disk"
