#!/usr/bin/env bash
set -euo pipefail

# Build the headless installer image: a bootable disk that runs installer/
# install.sh against a target disk. The built per-slot images are bundled inside
# the installer so it needs no network.
#
# Usage: make-installer.sh <rootfs> <arch> <outdir>

rootfs="${1:?usage: make-installer.sh <rootfs> <arch> <outdir>}"
arch="${2:?usage: make-installer.sh <rootfs> <arch> <outdir>}"
out="${3:?usage: make-installer.sh <rootfs> <arch> <outdir>}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/.." && pwd)"
project_root="$(cd "$os_dir/.." && pwd)"
work="$project_root/.build/os/$arch-a/installer"
stage="$work/rootfs"
arts="$work/artifacts"

log() { printf '[installer] %s\n' "$*" >&2; }
die() { printf '[installer] error: %s\n' "$*" >&2; exit 1; }

for f in root-a.img root-b.img obake-a.efi obake-b.efi; do
  [ -f "$out/$f" ] || die "missing built artifact: $out/$f"
done

rm -rf "$work"
mkdir -p "$work"
cp -a "$rootfs" "$stage"

log "bundling slot images and installer"
install -d "$stage/opt/obake/images"
for f in root-a.img root-b.img obake-a.efi obake-b.efi; do
  cp "$out/$f" "$stage/opt/obake/images/$f"
done
install -m 0755 "$project_root/installer/install.sh" "$stage/opt/obake/install.sh"
install -D -m 0644 "$os_dir/partition-layout.json" "$stage/opt/os/partition-layout.json"

# Optionally carry an SSH authorized key so the installer seeds it into the
# installed host's persist partition.
ssh_key="${OBKA_SSH_AUTHORIZED_KEY:-}"
if [ -n "$ssh_key" ] && [ -f "$ssh_key" ]; then
  install -d "$stage/opt/obake"
  install -m 0644 "$ssh_key" "$stage/opt/obake/authorized_key.pub"
fi

target_disk="${INSTALLER_TARGET_DISK:-/dev/vdb}"
preserve_user="${INSTALLER_PRESERVE_USER:-1}"

{
  cat <<'EOF'
[Unit]
Description=obake installer
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
EOF
  [ "$target_disk" != "interactive" ] &&
    printf 'Environment=TARGET_DISK=%s\n' "$target_disk"
  cat <<EOF
Environment=IMAGES_DIR=/opt/obake/images
Environment=PRESERVE_USER=$preserve_user
EOF
  if [ -n "$ssh_key" ] && [ -f "$ssh_key" ]; then
    printf 'Environment=OBKA_SSH_AUTHORIZED_KEY=/opt/obake/authorized_key.pub\n'
  fi
  cat <<'EOF'
ExecStart=/bin/sh -c '/opt/obake/install.sh < /dev/ttyS0; rc=$?; echo "OBKA_INSTALL_EXIT=$rc"; sync; /usr/bin/systemctl poweroff -f'
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0

[Install]
WantedBy=multi-user.target
EOF
} >"$stage/etc/systemd/system/obake-installer.service"
install -d "$stage/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/obake-installer.service \
  "$stage/etc/systemd/system/multi-user.target.wants/obake-installer.service"
# The installer owns the serial console for interactive selection.
ln -sf /dev/null "$stage/etc/systemd/system/serial-getty@ttyS0.service"

# Trim the installer rootfs: it does not use the target's mount contract, and
# its own labels must not collide with the target's (otherwise a disk-based
# installer booting by PARTLABEL can resolve the target's rootfs).
rm -f "$stage/etc/obake/etc-overlay"
cat >"$stage/etc/fstab" <<'EOF'
tmpfs /var tmpfs mode=0755 0 0
EOF

# The installer medium does not run the integration/update flows; drop the
# embedded update bundles to keep its root filesystem small.
rm -f "$stage"/opt/obake/*.raucb

log "packaging installer root filesystem"
size="$(du -sm "$stage" | cut -f1)"
size=$(( size + size / 10 + 512 ))
size=$(( (size + 63) / 64 * 64 ))
mke2fs -q -t ext4 -L OBKA_INSTALLER -d "$stage" -E root_owner=0:0 \
  "$work/installer-root.img" "${size}M"

log "building installer UKI"
kver="$(find "$rootfs/boot" -maxdepth 1 -name 'vmlinuz-*' | sed 's#.*/vmlinuz-##' | sort -V | tail -1)"
[ -n "$kver" ] || die "no kernel found in installer rootfs"
if [ "$arch" = "arm64" ]; then
  stub="/usr/lib/systemd/boot/efi/linuxaa64.efi.stub"
  boot_dst="BOOTAA64.EFI"
else
  stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
  boot_dst="BOOTX64.EFI"
fi
[ -f "$stub" ] || die "systemd EFI stub not found: $stub"
ukify build \
  --linux="$rootfs/boot/vmlinuz-$kver" \
  --initrd="$rootfs/boot/initrd.img-$kver" \
  --cmdline="root=PARTLABEL=OBKA_INSTALLER ro rootwait console=ttyS0 loglevel=7 efi=runtime" \
  --os-release="@$rootfs/etc/os-release" \
  --stub="$stub" \
  --output="$work/installer.efi"

log "assembling installer disk"
esp_mib=1024
total_mib=$(( esp_mib + size + 32 ))
disk="$work/installer.img"
rm -f "$disk"
truncate -s "${total_mib}M" "$disk"
sgdisk --zap-all "$disk" >/dev/null
sgdisk --new=1:2048:+"${esp_mib}"M \
  --typecode=1:C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
  --change-name=1:OBKA_INST "$disk" >/dev/null
sgdisk --new=2:0:+"${size}"M \
  --typecode=2:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --change-name=2:OBKA_INSTALLER "$disk" >/dev/null

esp_img="$work/esp.img"
rm -f "$esp_img"
truncate -s "${esp_mib}M" "$esp_img"
mkfs.vfat -F32 -n OBKA_INST "$esp_img" >/dev/null
mmd -i "$esp_img" ::/EFI ::/EFI/BOOT ::/EFI/Linux
mcopy -i "$esp_img" "$work/installer.efi" "::/EFI/BOOT/$boot_dst"
mcopy -i "$esp_img" "$work/installer.efi" "::/EFI/Linux/installer.efi"

start2="$(sgdisk -i 2 "$disk" | awk '/First sector/{print $3}')"
dd if="$esp_img" of="$disk" bs=512 seek=2048 conv=notrunc status=none
dd if="$work/installer-root.img" of="$disk" bs=512 seek="$start2" conv=notrunc status=none
cp "$disk" "$out/installer.img"
log "installer image ready: $out/installer.img"
