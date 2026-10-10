#!/usr/bin/env bash
set -euo pipefail

# Headless obake installer. Runs over a serial or text console, enumerates
# candidate disks, requires explicit confirmation, applies the shared partition
# layout, writes both A/B root slots and systemd-boot, and seeds the persist and
# user partitions. Re-running against an existing layout preserves the user
# partition.
#
# Partition devices are resolved relative to the selected target disk, not by
# global labels, so an installer medium that itself carries OBKA_* partitions
# cannot be confused with the target.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/.." && pwd)"
layout="${LAYOUT:-$project_root/os/partition-layout.json}"
layout_env="${LAYOUT_ENV:-${layout%.json}.env}"
images_dir="${IMAGES_DIR:?IMAGES_DIR must point at the staged per-slot artifacts}"
active_slot="${ACTIVE_SLOT:-a}"
target_disk="${TARGET_DISK:-}"
preserve_user="${PRESERVE_USER:-1}"
hostname="${OBKA_HOSTNAME:-obake}"

log() { printf '[install] %s\n' "$*" >&2; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }

# The build emits partition-layout.env next to partition-layout.json so the
# installer needs no Python on the target. Fall back to parsing the JSON with
# python3 when the env file is absent (development hosts).
if [ -f "$layout_env" ]; then
	# shellcheck disable=SC1090
	. "$layout_env"
	layout_rows() {
		local role order label guid size grow
		for role in $LAYOUT_ROLES; do
			eval "order=\$ROLE_${role}_ORDER label=\$ROLE_${role}_LABEL guid=\$ROLE_${role}_GUID size=\$ROLE_${role}_SIZE grow=\$ROLE_${role}_GROW"
			printf '%s %s %s %s %s %s\n' "$order" "$role" "$label" "$guid" "$size" "$grow"
		done
	}
	layout_field() { # <role> <field>
		eval "printf '%s\n' \"\${ROLE_${1}_$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')}\""
	}
	order_of() {
		eval "printf '%s\n' \"\${ROLE_${1}_ORDER}\""
	}
else
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
	order_of() {
		python3 - "$layout" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for p in data["partitions"]:
    if p["role"] == sys.argv[2]:
        print(p["order"])
        break
else:
    raise SystemExit(f"unknown role: {sys.argv[2]}")
PY
	}
fi

disk=""
partdev() { # partdev <order> -> /dev/<target partition>
  local order="$1" base d
  base="$(basename "$disk")"
  for d in /sys/class/block/"$base"*; do
    [ -f "$d/partition" ] || continue
    if [ "$(cat "$d/partition")" = "$order" ]; then
      printf '/dev/%s' "$(basename "$d")"
      return
    fi
  done
  printf '/dev/%s%s' "$base" "$order"
}

rolepart() { partdev "$(order_of "$1")"; }

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
  printf 'select destination disk: \n' >&2
  read -r answer
  [ -b "$answer" ] || die "not a block device: $answer"
  printf 'DESTROY %s and install obake? [y/N] \n' "$answer" >&2
  read -r confirm
  case "$confirm" in y | Y) ;; *) die "aborted" ;; esac
  printf '%s' "$answer"
}

has_user_partition() {
  [ -b "$(rolepart user)" ]
}

partition_disk() {
  local keep_user=0 order role
  if [ "$preserve_user" != 0 ] && has_user_partition; then
    keep_user=1
    log "preserving user partition $(layout_field user label)"
  fi

  if [ "$keep_user" = 1 ]; then
    for order in 1 2 3 4; do
      sgdisk --delete="$order" "$disk" >/dev/null || true
    done
  else
    sgdisk --zap-all "$disk" >/dev/null
  fi

  while read -r order role label guid size grow; do
    [ "$keep_user" = 1 ] && [ "$role" = user ] && continue
	local end
		case "$grow" in
		[Tt]rue | 1) end="0" ;;
		*) end="+${size}M" ;;
		esac
    sgdisk --new="${order}:0:${end}" \
      --typecode="${order}:${guid}" \
      --change-name="${order}:${label}" "$disk" >/dev/null
  done < <(layout_rows)
  partprobe "$disk" || true
  udevadm settle || true
}

format_partitions() {
  local keep_user="${1:-0}" role
  log "creating filesystems"
  mkfs.vfat -F32 -n "$(layout_field esp label)" "$(rolepart esp)" >/dev/null
  for role in root_a root_b persist; do
    mkfs.ext4 -q -F -L "$(layout_field "$role" label)" "$(rolepart "$role")"
  done
  if [ "$keep_user" = 0 ]; then
    mkfs.ext4 -q -F -L "$(layout_field user label)" "$(rolepart user)"
  fi
}

write_slot() {
  local slot="$1"
  local image="$images_dir/root-$slot.img"
  [ -f "$image" ] || die "missing slot image: $image"
  log "writing root slot $slot"
  dd if="$image" of="$(rolepart "root_$slot")" bs=4M status=none conv=fsync
}

seed_identity() {
  local persist="$1"
  printf '%s\n' "$hostname" >"$persist/etc/hostname"
  install -d "$persist/etc/systemd/network"
  cat >"$persist/etc/systemd/network/20-obake-wired.network" <<'EOF'
[Match]
Name=en* eth* end*

[Network]
DHCP=yes

[Link]
RequiredForOnline=no
EOF
  if [ ! -s "$persist/etc/machine-id" ]; then
    rm -f "$persist/etc/machine-id"
    systemd-machine-id-setup --root="$persist" >/dev/null
  fi
  if [ ! -s "$persist/etc/ssh/ssh_host_ed25519_key" ]; then
    install -d "$persist/etc/ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$persist/etc/ssh/ssh_host_ed25519_key"
    ssh-keygen -q -t rsa -b 3072 -N '' -f "$persist/etc/ssh/ssh_host_rsa_key"
  fi
  # Seed an SSH authorized key for the obake user on the persist partition, so
  # the installed host is reachable regardless of slot/update.
  if [ -n "${OBKA_SSH_AUTHORIZED_KEY:-}" ] && [ -f "$OBKA_SSH_AUTHORIZED_KEY" ]; then
    install -d "$persist/etc/ssh/authorized_keys.d"
    install -m 0644 "$OBKA_SSH_AUTHORIZED_KEY" \
      "$persist/etc/ssh/authorized_keys.d/obake"
  fi
}

install_boot() {
  local esp="/run/obka-esp" slot boot_dst part helper
  log "installing bootloader UKIs and EFI boot entries"
  case "$(uname -m)" in
  x86_64) boot_dst="BOOTX64.EFI" ;;
  aarch64 | arm64) boot_dst="BOOTAA64.EFI" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
  esac

  mkdir -p "$esp"
  mount "$(rolepart esp)" "$esp"
  mkdir -p "$esp/EFI/BOOT" "$esp/EFI/Linux"
  for slot in a b; do
    [ -f "$images_dir/obake-$slot.efi" ] || continue
    cp "$images_dir/obake-$slot.efi" "$esp/EFI/Linux/obake-$slot.efi"
  done
  # Firmware fallback: boot the active slot's UKI directly even without a
  # stored EFI boot entry.
  cp "$images_dir/obake-$active_slot.efi" "$esp/EFI/BOOT/$boot_dst"
  umount "$esp"

  # EFI boot entries A/B, with the active slot first, for RAUC's efi backend.
  [ -d /sys/firmware/efi ] || return 0
  if ! mountpoint -q /sys/firmware/efi/efivars; then
    modprobe efivarfs 2>/dev/null || true
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
  fi
  if ! mountpoint -q /sys/firmware/efi/efivars; then
    log "warning: EFI variables unavailable; relying on the firmware fallback"
    return 0
  fi

  part="$(order_of esp)"
  # One active A and one active B on this ESP. --force-order applies even
  # when a previous BootNext is still set.
  helper=/usr/libexec/obake/efi-boot-entries.sh
  [ -x "$helper" ] || die "EFI boot helper missing: $helper"
  "$helper" --disk "$disk" --part "$part" --prefer "$active_slot" --force-order
}

seed_persist() {
  local persist="/run/obka-persist"
  mkdir -p "$persist"
  mount "$(rolepart persist)" "$persist"
  mkdir -p "$persist/etc" "$persist/var" "$persist/etc-overlay/upper" "$persist/etc-overlay/work"
  seed_identity "$persist"
  umount "$persist"
}

seed_user() {
  local user="/run/obka-user"
  mkdir -p "$user"
  mount "$(rolepart user)" "$user"
  mkdir -p "$user/home"
  umount "$user"
}

disk="$(select_disk)"
keep_user=0
if [ "$preserve_user" != 0 ] && has_user_partition; then
  keep_user=1
fi
partition_disk
format_partitions "$keep_user"
write_slot a
write_slot b
install_boot
seed_persist
seed_user
sync
log "install complete"
printf 'OBKA_INSTALL_DONE\n'
