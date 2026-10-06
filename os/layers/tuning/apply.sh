#!/usr/bin/env bash
set -euo pipefail

# Tuning layer: host-level realtime and audio configuration. The udev rules and
# JACK profiles currently kept under host/ are installed here so the image,
# rather than a hand-provisioned host, carries them.

rootfs="${1:?usage: tuning/apply.sh <rootfs> <arch> [board]}"
arch="${2:?}"
board="${3:-generic}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
os_dir="$(cd "$here/../.." && pwd)"
project_root="$(cd "$os_dir/.." && pwd)"
host_dir="$project_root/host"

install -d "$rootfs/etc/udev/rules.d"
install -m 0644 "$host_dir"/udev/*.rules "$rootfs/etc/udev/rules.d/"

install -d "$rootfs/etc/jack"
install -m 0644 "$host_dir"/jack/*.conf "$rootfs/etc/jack/"
install -d "$rootfs/usr/lib/systemd/user"
install -m 0644 "$host_dir/jack/jack@.service" "$rootfs/usr/lib/systemd/user/jack@.service"

# Realtime scheduling and locked memory for audio users.
install -d "$rootfs/etc/security/limits.d"
cat >"$rootfs/etc/security/limits.d/obake-audio.conf" <<'EOF'
# obake realtime audio limits. Members of the audio group may use realtime
# scheduling and lock memory for low-latency audio work.
@audio   -  rtprio     95
@audio   -  memlock    unlimited
EOF

# Realtime-oriented kernel and inotify tuning.
install -d "$rootfs/etc/sysctl.d"
cat >"$rootfs/etc/sysctl.d/90-obake.conf" <<'EOF'
# obake host tuning.
vm.swappiness = 10
fs.inotify.max_user_watches = 524288
# Allow unprivileged reads of the kernel ring buffer (dmesg); the login user
# relies on it for diagnostics.
kernel.dmesg_restrict = 0
EOF

# Runtime mount contract. The root is mounted read-only by the kernel command
# line. /etc is overlaid from persist by the initramfs hook (see
# os/layers/tuning/files), /var is volatile with a persisted subset, and user
# data lives on the user partition. The persist partition is mounted by the
# initramfs hook so the /etc overlay exists before systemd reads config.
install -d "$rootfs/persist" "$rootfs/home" "$rootfs/var" "$rootfs/boot/efi"
cat >"$rootfs/etc/fstab" <<'EOF'
# <file system>        <mount point>  <type>  <options>                 <dump> <pass>
tmpfs                  /var           tmpfs   mode=0755                 0      0
LABEL=OBKA_USER        /home          ext4    defaults,noatime,x-systemd.growfs 0 2
LABEL=OBKA_ESP         /boot/efi      vfat    umask=0077                0      2
EOF

# Persisted subset of /var, bind-mounted from persist at boot.
install -d "$rootfs/etc/obake"
cat >"$rootfs/etc/obake/persisted-var" <<'EOF'
# Paths under /var that survive a reboot by being bind-mounted from
# /persist/var/<path>. One path per line, relative to /var.
lib/systemd
lib/NetworkManager
lib/singularity
log/journal
EOF

# Marker read by the initramfs hook to decide whether to overlay /etc.
: >"$rootfs/etc/obake/etc-overlay"

# The writable-location contract, surfaced to users. Only these paths (or their
# subtrees) accept persistent user changes; the rest of the root is read-only.
cat >"$rootfs/etc/obake/directory-contract" <<'EOF'
# obake writable directory contract. Locations a user may customize. Everything
# else on the root filesystem is read-only.
#
# /etc                   persistent overlay (survives boot and slot switch)
# /var                   volatile tmpfs; only the persisted subset survives
# /home                  user partition (survives updates and reinstalls)
# /persist               persist partition
EOF

# RAUC system configuration (native efi bootloader backend) and the state
# directory on the shared persist partition.
install -d "$rootfs/etc/rauc" "$rootfs/persist/rauc"
install -m 0644 "$os_dir/rauc/system.conf" "$rootfs/etc/rauc/system.conf"
if [ -n "${RAUC_KEYRING:-}" ] && [ -f "$RAUC_KEYRING" ]; then
  install -m 0644 "$RAUC_KEYRING" "$rootfs/etc/rauc/ca.cert.pem"
fi

if [ -n "${OBKA_SSH_AUTHORIZED_KEY:-}" ] && [ -f "$OBKA_SSH_AUTHORIZED_KEY" ]; then
  install -d "$rootfs/etc/ssh/authorized_keys.d"
  install -m 0644 "$OBKA_SSH_AUTHORIZED_KEY" "$rootfs/etc/ssh/authorized_keys.d/obake"
fi

# Update client configuration. The URL can be overridden at build time with
# UPDATE_URL; at runtime the file lives under the persistent /etc overlay.
cat >"$rootfs/etc/obake/update.conf" <<EOF
# obake update configuration.
#
# Point the host at a bundle source. Bundles are always signature-verified, so
# an HTTP/HTTPS endpoint and USB media are equally trustworthy.
https_url=${UPDATE_URL:-}
usb_prefer=${USB_PREFER:-1}
# tls_cacert=/etc/obake/update-ca.pem
# tls_insecure=0
local_bundle=${LOCAL_BUNDLE:-}
EOF

# Health gate configuration. Development mock: mock_health is pass|fail.
cat >"$rootfs/etc/obake/health.conf" <<EOF
# obake health gate configuration.
max_attempts=${HEALTH_MAX_ATTEMPTS:-3}
mock_health=${MOCK_HEALTH:-pass}
EOF

# /persist is mounted by the initramfs; make sure RAUC's state directory exists
# at boot.
install -d "$rootfs/etc/tmpfiles.d"
cat >"$rootfs/etc/tmpfiles.d/obake-rauc.conf" <<'EOF'
d /persist/rauc 0755 root root -
EOF

# Enable the D-Bus system socket the RAUC service is activated on.
install -d "$rootfs/etc/systemd/system/sockets.target.wants"
ln -sf /usr/lib/systemd/system/dbus.socket \
  "$rootfs/etc/systemd/system/sockets.target.wants/dbus.socket"

# Network: DHCP on wired interfaces via systemd-networkd, so a freshly built or
# installed host (and the verification harness) can reach an update service.
install -d "$rootfs/etc/systemd/network"
cat >"$rootfs/etc/systemd/network/20-obake-wired.network" <<'EOF'
[Match]
Name=en* eth* end*

[Network]
DHCP=yes
EOF
install -d "$rootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/systemd-networkd.service \
  "$rootfs/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /usr/lib/systemd/system/systemd-networkd-wait-online.service \
  "$rootfs/etc/systemd/system/multi-user.target.wants/systemd-networkd-wait-online.service"

# systemd-resolved provides DNS from DHCP; avahi provides mDNS (.local).
ln -sf /usr/lib/systemd/system/systemd-resolved.service \
  "$rootfs/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
ln -sf /usr/lib/systemd/system/avahi-daemon.service \
  "$rootfs/etc/systemd/system/multi-user.target.wants/avahi-daemon.service"
# polkit authorizes non-root systemctl actions (see the obake rules drop-in).
ln -sf /usr/lib/systemd/system/polkit.service \
  "$rootfs/etc/systemd/system/multi-user.target.wants/polkit.service"

[ -d "$here/files" ] && cp -a "$here/files/." "$rootfs/"

# Files shipped from the repository keep the build user's ownership; sshd's
# StrictModes requires the authorized-keys path to be root-owned.
chown -R 0:0 "$rootfs/etc/ssh" 2>/dev/null || true
# polkit only trusts rules owned by root.
chown -R 0:0 "$rootfs/etc/polkit-1" 2>/dev/null || true
# /etc/hosts is bind-mounted into containers by Singularity; keep it root-owned.
chown 0:0 "$rootfs/etc/hosts" 2>/dev/null || true
