#!/usr/bin/env bash
set -euo pipefail

# Layered obake OS image build.
#
# The base layer is a minimal Debian rootfs produced by mmdebstrap. Every
# higher layer (kernel, tuning, runtime, board) is expressed as additional
# packages plus a `files/` tree and an `apply.sh` overlay, and is applied to the
# unpacked rootfs. See README.md for the layer model.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$here/.." && pwd)"
manifest="$here/manifest.json"
layout="$here/partition-layout.json"

arch="${ARCH:-amd64}"
suite="${SUITE:-}"
slot="${SLOT:-a}"
board="${BOARD:-generic}"
version="${VERSION:-0.0.0}"
mirror="${MIRROR:-}"
work="${WORK:-$project_root/.build/os/$arch-$slot}"
out="${OUT:-$project_root/dist/os/$arch}"
make_disk="${MAKE_DISK:-0}"
make_installer="${MAKE_INSTALLER:-0}"
verify="${VERIFY:-0}"
break="${BREAK:-}"

log() { printf '[build] %s\n' "$*" >&2; }
die() { printf '[build] error: %s\n' "$*" >&2; exit 1; }

# --- manifest helpers -------------------------------------------------------

mf() {
  python3 - "$manifest" "$@" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
node = data
for key in sys.argv[2:]:
    if key == "":
        continue
    if isinstance(node, list):
        node = node[int(key)]
    else:
        node = node[key]
if isinstance(node, (dict, list)):
    print(json.dumps(node))
elif node is None:
    print("")
else:
    print(node)
PY
}

mf_list() { python3 - "$manifest" "$@" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for key in sys.argv[2:-1]:
    node = node[key]
items = node.get(sys.argv[-1], [])
print("\n".join(items))
PY
}

layout_field() {
  python3 - "$layout" "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for part in data["partitions"]:
    if part["role"] == sys.argv[2]:
        print(part[sys.argv[3]])
        break
else:
    raise SystemExit(f"unknown role: {sys.argv[2]}")
PY
}

# --- pinned inputs ----------------------------------------------------------

suite="${suite:-$(mf base suite)}"
mirror="${mirror:-$(mf base mirror)}"
security_mirror="$(mf base securityMirror)"
security_suite="${SECURITY_SUITE:-$(mf base securitySuite)}"
keyring="$(mf base keyring)"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}" # 2024-01-01

# mmdebstrap takes a single MIRROR argument that may itself be a sources.list
# fragment, so the stable suite and its security suite are combined here.
mirror_spec="deb [signed-by=$keyring] $mirror $suite main
deb [signed-by=$keyring] $security_mirror $security_suite main"

kernel_meta="$(mf kernel meta "$arch")"
kernel_meta_version="${KERNEL_META_VERSION:-$(mf kernel metaVersion)}"
kernel_image="$(mf kernel image "$arch")"
singularity_version="$(mf singularity version)"

[ -n "$kernel_meta" ] || die "no kernel meta-package for arch $arch"

arch_packages() {
  mf_list base packages
  mf_list layers runtime packages
  printf '%s=%s\n' "$kernel_meta" "$kernel_meta_version"
  if [ "$arch" = "amd64" ]; then
    mf_list layers tuning packages
  fi
  python3 - "$manifest" "$board" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
board = data.get("boards", {}).get(sys.argv[2])
if board is None:
    raise SystemExit(f"unknown board: {sys.argv[2]}")
print("\n".join(board.get("packages", [])))
PY
}

cmdline_for_slot() {
  local slot="$1" mode="ro"
  [ "$break" = "ro" ] && mode="rw"
  printf 'root=PARTLABEL=%s %s rootwait console=ttyS0 loglevel=7 efi=runtime' \
    "$(layout_field "root_$slot" label)" "$mode"
}

# --- build steps ------------------------------------------------------------

rootfs="$work/rootfs"
slots="${SLOTS:-a b}"

build_rootfs() {
  log "building $arch/$suite base rootfs (pinned kernel $kernel_image)"
  rm -rf "$work"
  mkdir -p "$work"
  local include
  include="$(arch_packages | paste -sd, -)"
  mmdebstrap \
    --architectures="$arch" \
    --variant="$(mf base variant)" \
    --include="$include" \
    --components="main" \
    --aptopt="Acquire::Retries=3" \
    "$suite" "$rootfs" "$mirror_spec"
  log "applying obake layers"
  "$here/scripts/install-layers.sh" "$rootfs" "$arch" "$board"
}

regen_initrd() {
  # The layers add initramfs hooks (persistent /etc overlay), so the initramfs
  # generated during package installation must be rebuilt after the overlays.
  log "regenerating initramfs"
  if [ "$arch" != "$(dpkg --print-architecture)" ]; then
    log "skipping initramfs regeneration for foreign arch $arch"
    return 0
  fi
  chroot "$rootfs" update-initramfs -u -k all
}

apply_break() {
  # Deliberate fault injection so the harness can prove each functional check
  # fails when its behavior is broken.
  case "$break" in
  "") ;;
  ro) log "BREAK: root will be mounted read-write" ;;
  etc) log "BREAK: disabling the /etc overlay"; rm -f "$rootfs/etc/obake/etc-overlay" ;;
  var) log "BREAK: /var will not be tmpfs"; sed -i '\#tmpfs[[:space:]]*/var#d' "$rootfs/etc/fstab" ;;
  user) log "BREAK: /home will not be mounted"; sed -i '\#OBKA_USER#d' "$rootfs/etc/fstab" ;;
  *) die "unknown BREAK value: $break" ;;
  esac
}

install_verify() {
  [ "$verify" = "1" ] || return 0
  install -d "$rootfs/usr/libexec/obake" \
    "$rootfs/etc/systemd/system/multi-user.target.wants"

  if [ "${VERIFY_HEALTH:-0}" = "1" ]; then
    log "installing health-gate functional test"
    install -m 0755 "$project_root/verification/guest/obake-health-test.sh" \
      "$rootfs/usr/libexec/obake/obake-health-test.sh"
    if [ -n "${VERIFY_UPDATE_BUNDLE:-}" ] && [ -f "$VERIFY_UPDATE_BUNDLE" ]; then
      install -d "$rootfs/opt/obake"
      install -m 0644 "$VERIFY_UPDATE_BUNDLE" "$rootfs/opt/obake/update.raucb"
    fi
    cat >"$rootfs/etc/systemd/system/obake-health-test.service" <<'EOF'
[Unit]
Description=obake health-gate functional test
After=obake-runtime.target obake-health-gate.service multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/obake/obake-health-test.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/obake-health-test.service \
      "$rootfs/etc/systemd/system/multi-user.target.wants/obake-health-test.service"
    return 0
  fi

  if [ "${VERIFY_INTEGRATION:-0}" = "1" ]; then
    log "installing integration test"
    install -m 0755 "$project_root/verification/guest/obake-integration-test.sh" \
      "$rootfs/usr/libexec/obake/obake-integration-test.sh"
    install -d "$rootfs/opt/obake"
    [ -n "${VERIFY_INTEGRATION_GOOD:-}" ] &&
      install -m 0644 "$VERIFY_INTEGRATION_GOOD" "$rootfs/opt/obake/good.raucb"
    [ -n "${VERIFY_INTEGRATION_BAD:-}" ] &&
      install -m 0644 "$VERIFY_INTEGRATION_BAD" "$rootfs/opt/obake/bad.raucb"
    cat >"$rootfs/etc/systemd/system/obake-integration-test.service" <<'EOF'
[Unit]
Description=obake integration test
After=obake-health-gate.service obake-runtime.target multi-user.target
Wants=multi-user.target
ConditionPathExists=/persist/obake-integration

[Service]
Type=oneshot
ExecStart=/usr/libexec/obake/obake-integration-test.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/obake-integration-test.service \
      "$rootfs/etc/systemd/system/multi-user.target.wants/obake-integration-test.service"
    return 0
  fi

  if [ "${VERIFY_PERSIST:-0}" = "1" ]; then
    log "installing writable-contract persistence test"
    install -m 0755 "$project_root/verification/guest/obake-persist-test.sh" \
      "$rootfs/usr/libexec/obake/obake-persist-test.sh"
    cat >"$rootfs/etc/systemd/system/obake-persist-test.service" <<'EOF'
[Unit]
Description=obake writable-contract persistence test
After=obake-persist-var.service obake-runtime.target multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/obake/obake-persist-test.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/obake-persist-test.service \
      "$rootfs/etc/systemd/system/multi-user.target.wants/obake-persist-test.service"
    return 0
  fi

  if [ -n "${VERIFY_UPDATE_BUNDLE:-}" ] || [ "${VERIFY_UPDATE:-0}" = "1" ]; then
    log "installing RAUC update functional test"
    install -m 0755 "$project_root/verification/guest/obake-update-test.sh" \
      "$rootfs/usr/libexec/obake/obake-update-test.sh"
    if [ -n "${VERIFY_UPDATE_BUNDLE:-}" ] && [ -f "$VERIFY_UPDATE_BUNDLE" ]; then
      install -d "$rootfs/opt/obake"
      install -m 0644 "$VERIFY_UPDATE_BUNDLE" "$rootfs/opt/obake/update.raucb"
    fi
    cat >"$rootfs/etc/systemd/system/obake-update-test.service" <<'EOF'
[Unit]
Description=obake RAUC update functional test
After=obake-efi-entries.service multi-user.target network-online.target
Wants=multi-user.target network-online.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/obake/obake-update-test.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    ln -sf /etc/systemd/system/obake-update-test.service \
      "$rootfs/etc/systemd/system/multi-user.target.wants/obake-update-test.service"
    return 0
  fi

  log "installing guest functional checks"
  install -m 0755 "$project_root/verification/guest/obake-verify.sh" \
    "$rootfs/usr/libexec/obake/obake-verify.sh"
  cat >"$rootfs/etc/systemd/system/obake-verify.service" <<'EOF'
[Unit]
Description=obake guest functional checks
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/libexec/obake/obake-verify.sh; rc=$?; echo "OBKA_VERIFY_EXIT=$rc"; sync; /usr/bin/systemctl poweroff -f'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
  ln -sf /etc/systemd/system/obake-verify.service \
    "$rootfs/etc/systemd/system/multi-user.target.wants/obake-verify.service"
}

create_sysusers() {
  # Materialize sysusers entries (e.g. the obake login user) into the image so
  # the target does not depend on the runtime sysusers pass alone.
  [ -x "$rootfs/usr/bin/systemd-sysusers" ] || return 0
  [ "$arch" = "$(dpkg --print-architecture)" ] || return 0
  log "creating system users"
  chroot "$rootfs" systemd-sysusers || true
  # systemd-sysusers locks the account ("!*"). Unlock it for SSH key auth with a
  # no-password marker; password auth still fails.
  sed -i 's/^\(obake:\)![^:]*:/\1*:/' "$rootfs/etc/shadow" 2>/dev/null || true
}

normalize_rootfs() {
  # Make clean builds converge: drop host-copied files and pin every timestamp
  # to SOURCE_DATE_EPOCH so the rootfs and the initramfs it produces are
  # reproducible across builds.
  log "normalizing rootfs for reproducible output"
  rm -f "$rootfs/etc/resolv.conf"
  # SSH host keys are machine-specific and seeded on the persist partition at
  # install time; the package-generated ones would make builds non-reproducible.
  rm -f "$rootfs"/etc/ssh/ssh_host_*
  find "$rootfs" -xdev -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true
}

build_uki() {
  local slot="$1"
  log "building UKI for slot $slot"
  local kver stub
  kver="$(find "$rootfs/boot" -maxdepth 1 -name 'vmlinuz-*' | sed 's#.*/vmlinuz-##' | sort -V | tail -1)"
  [ -n "$kver" ] || die "no kernel found in rootfs"
  if [ "$arch" = "arm64" ]; then
    stub="/usr/lib/systemd/boot/efi/linuxaa64.efi.stub"
  else
    stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
  fi
  [ -f "$stub" ] || die "systemd EFI stub not found: $stub"
  mkdir -p "$out"
  ukify build \
    --linux="$rootfs/boot/vmlinuz-$kver" \
    --initrd="$rootfs/boot/initrd.img-$kver" \
    --cmdline="$(cmdline_for_slot "$slot")" \
    --os-release="@$rootfs/etc/os-release" \
    --stub="$stub" \
    --output="$out/obake-$slot.efi"
  printf '%s\n' "$kver" >"$out/kernel-version-$slot"
}

make_image() {
  local slot="$1" label uuid
  label="$(layout_field "root_$slot" label)"
  uuid="$(python3 -c 'import uuid,sys; print(uuid.uuid5(uuid.NAMESPACE_URL, "obake-root-image:" + sys.argv[1]))' "$label")"
  log "packaging rootfs image for slot $slot"
  mkdir -p "$out"
  local size
  size="$(du -sm "$rootfs" | cut -f1)"
  # Leave room for filesystem metadata and slack (larger rootfs images, e.g.
  # those carrying embedded update bundles, need more than a fixed offset).
  size=$(( size + size / 10 + 256 ))
  size=$(( (size + 63) / 64 * 64 ))
  rm -f "$out/root-$slot.img"
  mke2fs -q -t ext4 -L "$label" -U "$uuid" -d "$rootfs" -E "root_owner=0:0" \
    "$out/root-$slot.img" "${size}M"
}

make_tar() {
  # The canonical, reproducible layer artifact. mke2fs -d is not deterministic,
  # so the ext4 image above is a derived boot artifact while this archive is the
  # byte-reproducible one used to verify clean builds match.
  local slot="$1"
  log "packaging reproducible rootfs archive for slot $slot"
  mkdir -p "$out"
  tar -C "$rootfs" --sort=name --numeric-owner --owner=0 --group=0 \
    --mtime="@$SOURCE_DATE_EPOCH" --format=gnu \
    -cf "$out/root-$slot.tar" .
}

make_disk_image() {
  log "assembling bootable disk image"
  "$here/scripts/make-disk.sh" "$slot" "$arch" "$out"
}

make_installer_image() {
  log "building installer image"
  "$here/scripts/make-installer.sh" "$rootfs" "$arch" "$out"
}

sign() {
  log "signing artifacts"
  "$here/scripts/sign.sh" "$out"
}

build_rootfs
apply_break
install_verify
create_sysusers
install -d "$rootfs/etc/obake"
printf '%s\n' "$version" >"$rootfs/etc/obake/image-version"
if [ -n "${IMAGE_TAG:-}" ]; then
  install -d "$rootfs/etc/obake"
  printf '%s\n' "$IMAGE_TAG" >"$rootfs/etc/obake/image-tag"
fi
normalize_rootfs
regen_initrd
normalize_rootfs
for s in $slots; do
  build_uki "$s"
  make_image "$s"
  make_tar "$s"
done
[ "$make_disk" = "1" ] && make_disk_image
[ "$make_installer" = "1" ] && make_installer_image
sign
log "done: $out (version $version, kernel $kernel_image)"
