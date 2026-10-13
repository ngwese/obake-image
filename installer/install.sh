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
hostname=""

log() { printf '[install] %s\n' "$*" >&2; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }

# RFC1123 host name check, matching what systemd's hostname_is_valid accepts.
is_valid_hostname() {
	local h="$1" label
	[ -n "$h" ] && [ "${#h}" -le 64 ] || return 1
	case "$h" in
	-* | *- | .* | *. | *..*) return 1 ;;
	esac
	local IFS=.
	for label in $h; do
		[ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
		case "$label" in
		-* | *-) return 1 ;;
		*[!A-Za-z0-9-]*) return 1 ;;
		esac
	done
	return 0
}

# Resolve the host name from the OBKA_HOSTNAME seed (default obake). An
# interactive install (no fixed target disk) prompts on the console with the
# seed as the default; a non-interactive install uses the seed directly. Only a
# valid name is accepted: interactive re-prompts, non-interactive fails.
resolve_hostname() {
	local seed="${OBKA_HOSTNAME:-obake}" answer
	if [ -n "$target_disk" ]; then
		is_valid_hostname "$seed" || die "invalid OBKA_HOSTNAME: $seed"
		printf '%s' "$seed"
		return 0
	fi
	while :; do
		printf 'host name [%s]: \n' "$seed" >&2
		read -r answer
		[ -n "$answer" ] || answer="$seed"
		if is_valid_hostname "$answer"; then
			printf '%s' "$answer"
			return 0
		fi
		printf 'invalid host name: %s\n' "$answer" >&2
	done
}

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
  local persist="$1" upper="$1/etc-overlay/upper" stage
  install -d "$upper"
  # Build the identity in a staging root (so systemd-machine-id-setup and
  # ssh-keygen see a normal layout), then copy it into the /etc overlay upper
  # the installed host actually reads. Writing to $persist/etc would be dead,
  # since the runtime overlays /etc from $upper.
  stage="$(mktemp -d)"
  install -d "$stage/etc/systemd/network" "$stage/etc/ssh"
  printf '%s\n' "$hostname" >"$stage/etc/hostname"
  cat >"$stage/etc/systemd/network/20-obake-wired.network" <<'EOF'
[Match]
Name=en* eth* end*

[Network]
DHCP=yes

[Link]
RequiredForOnline=no
EOF
  systemd-machine-id-setup --root="$stage" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$stage/etc/ssh/ssh_host_ed25519_key"
  ssh-keygen -q -t rsa -b 3072 -N '' -f "$stage/etc/ssh/ssh_host_rsa_key"
  cp -a "$stage/etc/." "$upper/"
  chown -R 0:0 "$upper"
  rm -rf "$stage"
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
  mkdir -p "$persist/var" "$persist/etc-overlay/upper" "$persist/etc-overlay/work"
  seed_identity "$persist"
  umount "$persist"
}

seed_user() {
  local user="/run/obka-user" home uid gid target
  mkdir -p "$user"
  mount "$(rolepart user)" "$user"
  # The user partition mounts at /home, so its root is /home and obake's home
  # is /obake within it.
  home="$user/obake"
  uid="${OBKA_USER_UID:-$(id -u obake 2>/dev/null || true)}"
  gid="${OBKA_USER_GID:-$(id -g obake 2>/dev/null || true)}"
  [ -n "$uid" ] && [ -n "$gid" ] ||
    die "obake user not found in the installer environment"
  mkdir -p "$home"
  chown "$uid:$gid" "$home"
  chmod 0755 "$home"
  # Seed the build-time authorized key for obake into the user's home on the
  # user partition, only when the user has no key yet, so a reinstall that
  # preserves user data never overwrites a user-managed key. The user owns the
  # file and can replace it without elevated privileges.
  if [ -n "${OBKA_SSH_AUTHORIZED_KEY:-}" ] && [ -f "$OBKA_SSH_AUTHORIZED_KEY" ]; then
    target="$home/.ssh/authorized_keys"
    if [ ! -e "$target" ]; then
      install -d -m 0700 -o "$uid" -g "$gid" "$home/.ssh"
      install -m 0600 -o "$uid" -g "$gid" \
        "$OBKA_SSH_AUTHORIZED_KEY" "$target"
    fi
  fi
  umount "$user"
}

disk="$(select_disk)"
hostname="$(resolve_hostname)"
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
