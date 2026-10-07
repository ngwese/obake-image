#!/usr/bin/env bash
#
# Build the headless installer medium from the Buildroot build: a bootable disk
# that runs installer/install.sh against a target disk. The built per-slot
# images and UKIs are bundled inside the installer so it needs no network.
#
# Invoked by post-image.sh when MAKE_INSTALLER=1.
set -euo pipefail

binaries="${1:?usage: make-installer.sh <binaries-dir>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extroot="$(cd "$here/../.." && pwd)"
os_dir="$(cd "$extroot/.." && pwd)"
image_dir="$(cd "$os_dir/.." && pwd)"
scripts="$os_dir/scripts"
layout="${LAYOUT:-$os_dir/partition-layout.json}"

log() { printf '[installer] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

case "$(grep -E '^BR2_(aarch64|x86_64)=y' "$BR2_CONFIG")" in
*BR2_aarch64=y*) arch=aarch64; kern=Image; efiarch=aa64; cons=ttyAMA0 ;;
*BR2_x86_64=y*) arch=x86_64; kern=bzImage; efiarch=x64; cons=ttyS0 ;;
*) die "unsupported architecture" ;;
esac

for f in root-a.img root-b.img obake-a.efi obake-b.efi; do
	[ -f "$binaries/$f" ] || die "missing built artifact: $binaries/$f"
done

stub="$TARGET_DIR/usr/lib/systemd/boot/efi/linux$efiarch.efi.stub"
[ -f "$stub" ] || stub="$extroot/vendor/efi-stub/linux$efiarch.efi.stub"
[ -f "$stub" ] || die "EFI stub not found"
ukify="$(command -v ukify || true)"
[ -n "$ukify" ] || ukify="$HOST_DIR/bin/ukify"
[ -x "$ukify" ] || die "ukify not found"

work="$binaries/.installer"
stage="$work/rootfs"
rm -rf "$work"
mkdir -p "$work"
cp -a "$TARGET_DIR" "$stage"

log "bundling slot images and installer"
install -d "$stage/opt/obake/images" "$stage/opt/os"
for f in root-a.img root-b.img obake-a.efi obake-b.efi; do
	cp "$binaries/$f" "$stage/opt/obake/images/$f"
done
install -m 0755 "$image_dir/installer/install.sh" "$stage/opt/obake/install.sh"
install -m 0644 "$layout" "$stage/opt/os/partition-layout.json"
python3 - "$layout" >"$stage/opt/os/partition-layout.env" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print('LAYOUT_ROLES="%s"' % " ".join(p["role"] for p in d["partitions"]))
for p in d["partitions"]:
    r = p["role"]
    print('ROLE_%s_ORDER=%s' % (r, p["order"]))
    print('ROLE_%s_LABEL=%s' % (r, p["label"]))
    print('ROLE_%s_GUID=%s' % (r, p["typeGuid"]))
    print('ROLE_%s_SIZE=%s' % (r, p["sizeMiB"]))
    print('ROLE_%s_GROW=%s' % (r, str(p.get("grow", False)).lower()))
PY

ssh_key="${OBKA_SSH_AUTHORIZED_KEY:-}"
if [ -n "$ssh_key" ] && [ -f "$ssh_key" ]; then
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
	[ "$target_disk" != "interactive" ] && printf 'Environment=TARGET_DISK=%s\n' "$target_disk"
	printf 'Environment=IMAGES_DIR=/opt/obake/images\n'
	printf 'Environment=PRESERVE_USER=%s\n' "$preserve_user"
	[ -n "$ssh_key" ] && printf 'Environment=OBKA_SSH_AUTHORIZED_KEY=/opt/obake/authorized_key.pub\n'
	printf 'Environment=LAYOUT_ENV=/opt/os/partition-layout.env\n'
	cat <<EOF
ExecStart=/bin/sh -c '/opt/obake/install.sh < /dev/$cons; rc=\$?; echo "OBKA_INSTALL_EXIT=\$rc"; sync; /usr/bin/systemctl poweroff -f'
StandardOutput=tty
StandardError=tty
TTYPath=/dev/$cons

[Install]
WantedBy=multi-user.target
EOF
} >"$stage/etc/systemd/system/obake-installer.service"
install -d "$stage/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/obake-installer.service \
	"$stage/etc/systemd/system/multi-user.target.wants/obake-installer.service"
ln -sf /dev/null "$stage/etc/systemd/system/serial-getty@$cons.service"

# The installer rootfs does not use the target's mount contract, and its own
# labels must not collide with the target's.
rm -f "$stage/etc/obake/etc-overlay"
printf 'tmpfs /var tmpfs mode=0755 0 0\n' >"$stage/etc/fstab"
rm -f "$stage"/opt/obake/*.raucb

log "packaging installer rootfs"
size="$(du -sm "$stage" | cut -f1)"
size=$(( size + size / 10 + 512 ))
size=$(( (size + 63) / 64 * 64 ))
rm -f "$work/installer-root.img"
mke2fs -q -t ext4 -L OBKA_INSTALLER -d "$stage" -E root_owner=0:0 \
	"$work/installer-root.img" "${size}M"

log "building installer UKI"
"$ukify" build \
	--linux="$binaries/$kern" \
	--initrd="$binaries/initramfs.gz" \
	--cmdline="root=PARTLABEL=OBKA_INSTALLER ro rootwait console=$cons loglevel=7 efi=runtime" \
	--os-release="@$TARGET_DIR/etc/os-release" \
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
if [ "$efiarch" = "aa64" ]; then boot_dst="BOOTAA64.EFI"; else boot_dst="BOOTX64.EFI"; fi
mcopy -i "$esp_img" "$work/installer.efi" "::/EFI/BOOT/$boot_dst"
mcopy -i "$esp_img" "$work/installer.efi" "::/EFI/Linux/installer.efi"

start2="$(sgdisk -i 2 "$disk" | awk '/First sector/{print $3}')"
dd if="$esp_img" of="$disk" bs=512 seek=2048 conv=notrunc status=none
dd if="$work/installer-root.img" of="$disk" bs=512 seek="$start2" conv=notrunc status=none
cp "$disk" "$binaries/installer.img"
log "installer image ready: $binaries/installer.img"
