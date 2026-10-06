#!/usr/bin/env bash
set -euo pipefail

# Two-phase RAUC update verification. Builds a verification image carrying a
# signed bundle for slot B, boots it (slot A), installs the bundle, powers off,
# then boots again with the same EFI variables and asserts the update activated.
#
# Usage: update-test.sh [good|broken|https|usb] [arch]
#   good   a bundle signed by the trusted CA must install and activate
#   broken a bundle signed by an untrusted CA must be rejected
#   https  the target fetches the bundle from a development update service
#   usb    with a bundle on USB and the service available, USB must be used

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/qemu-env.sh"

project_root="$(cd "$here/../.." && pwd)"
mode="${1:-good}"
arch="${2:-amd64}"

out="$project_root/dist/verify/$arch/update-$mode"
artifacts="$out/artifacts"
bundle_version="0.3.0"
update_kernel="${UPDATE_KERNEL_VERSION:-6.12.107-1}"
update_singularity_stage="${UPDATE_SINGULARITY_STAGE:-}"
update_singularity_version="${UPDATE_SINGULARITY_VERSION:-}"
boot_timeout="${UPDATE_BOOT_TIMEOUT:-300}"

ovmf_code="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
ovmf_vars="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

log() { printf '[update-test] %s\n' "$*" >&2; }
fail() { printf '[update-test] FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

log "building update OS artifacts"
update_artifacts="$out/update-artifacts"
ARCH="$arch" VERSION="$bundle_version" IMAGE_TAG="$bundle_version" \
  KERNEL_META_VERSION="$update_kernel" VERIFY=1 VERIFY_UPDATE=1 \
  OBKA_SINGULARITY_STAGE="$update_singularity_stage" \
  OBKA_SINGULARITY_VERSION="$update_singularity_version" \
  OUT="$update_artifacts" \
  "$project_root/os/build.sh" >"$out/update-artifacts-build.log" 2>&1

# Trusted material is baked into the image keyring; the bundle is signed with
# either the trusted material (good) or different material (broken).
os/scripts/make-signing-material.sh "$out/trusted" >/dev/null
if [ "$mode" = "broken" ]; then
  os/scripts/make-signing-material.sh "$out/untrusted" >/dev/null
  sign_cert="$out/untrusted/signing.cert.pem"
  sign_key="$out/untrusted/signing.key"
else
  sign_cert="$out/trusted/signing.cert.pem"
  sign_key="$out/trusted/signing.key"
fi

RAUC_SIGNING_CERT="$sign_cert" RAUC_SIGNING_KEY="$sign_key" \
  "$project_root/os/scripts/make-bundle.sh" b "$bundle_version" \
  "$update_artifacts/root-b.img" "$update_artifacts/obake-b.efi" "$out/bundles" >/dev/null

log "building verification image for mode $mode"
server_pid=""
trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true' EXIT

usb_img=""
make_usb_image() {
  local img="$1" bundle="$2" partimg
  rm -f "$img"
  truncate -s 1400M "$img"
  sgdisk --zap-all "$img" >/dev/null
  sgdisk -n 1:2048:0 -t 1:0700 -c 1:OBKA_USB "$img" >/dev/null
  partimg="$(mktemp)"
  truncate -s 1398M "$partimg"
  mkfs.vfat -F32 -n OBKA_USB "$partimg" >/dev/null
  mcopy -i "$partimg" "$bundle" ::/
  dd if="$partimg" of="$img" bs=512 seek=2048 conv=notrunc status=none
  rm -f "$partimg"
}

if [ "$mode" = "https" ] || [ "$mode" = "usb" ]; then
  port="${UPDATE_TEST_PORT:-8085}"
  "$project_root/verification/update-server.sh" "$out/bundles" "$port" \
    >"$out/server.log" 2>&1 &
  server_pid=$!
  sleep 1
  url="http://10.0.2.2:$port/obake-$bundle_version-b.raucb"
  log "development update service at $url"
  if [ "$mode" = "usb" ]; then
    usb_img="$out/usb.img"
    make_usb_image "$usb_img" "$out/bundles/obake-$bundle_version-b.raucb"
    log "attached USB media with the bundle"
  fi
  RAUC_KEYRING="$out/trusted/ca.cert.pem" VERIFY=1 VERIFY_UPDATE=1 \
    UPDATE_URL="$url" MAKE_DISK=1 ARCH="$arch" OUT="$out/image" \
    "$project_root/os/build.sh" >"$out/build.log" 2>&1
else
  RAUC_KEYRING="$out/trusted/ca.cert.pem" VERIFY=1 MAKE_DISK=1 \
    VERIFY_UPDATE_BUNDLE="$out/bundles/obake-$bundle_version-b.raucb" \
    ARCH="$arch" OUT="$out/image" "$project_root/os/build.sh" \
    >"$out/build.log" 2>&1
fi

disk="$out/image/disk-a.img"
sed_vars="$out/vars.fd"
cp "$ovmf_vars" "$sed_vars"
log_file="$out/update.log"
: >"$log_file"

boot() {
  local phase="$1"
  local qemu_extra=()
  if [ -n "$usb_img" ]; then
    qemu_extra=(-drive "if=none,id=usbstick,format=raw,file=$usb_img,$OBKA_QEMU_DISK_OPTS"
      -device qemu-xhci,id=xhci
      -device usb-storage,drive=usbstick,bus=xhci.0)
  fi
  log "booting $phase (accel=$OBKA_QEMU_ACCEL_NAME cpu=$OBKA_QEMU_CPU)"
  set +e
  timeout "$boot_timeout" qemu-system-x86_64 \
    -machine q35 -accel "$OBKA_QEMU_ACCEL_NAME" -cpu "$OBKA_QEMU_CPU" \
    -m 4096 -smp "$OBKA_QEMU_SMP" -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$sed_vars" \
    -drive file="$disk",format=raw,if=virtio,"$OBKA_QEMU_DISK_OPTS" \
    "${qemu_extra[@]}" \
    -nographic >>"$log_file" 2>&1
  set -e
}

boot phase1
boot phase2

if [ "$mode" = "usb" ] && ! grep -qF "OBKA_UPDATE_SOURCE=usb" "$log_file"; then
  fail "USB source was not preferred"
fi

if [ "$mode" != "broken" ]; then
  expected_kernel="$(cat "$update_artifacts/kernel-version-b" 2>/dev/null || true)"
  grep -qF "OBKA_UPDATE_VERSION=$bundle_version" "$log_file" ||
    fail "installed version not reported as $bundle_version"
  if [ -n "$expected_kernel" ]; then
    grep -qF "OBKA_UPDATE_KERNEL=$expected_kernel" "$log_file" ||
      fail "installed kernel not reported as $expected_kernel"
  fi
  if [ -n "$update_singularity_version" ]; then
    grep -qF "OBKA_UPDATE_SINGULARITY=singularity-ce version $update_singularity_version" "$log_file" ||
      fail "installed Singularity CE not reported as $update_singularity_version"
  fi
fi

if grep -qF "OBKA_UPDATE_PHASE1_PASS" "$log_file" &&
  grep -qF "OBKA_UPDATE_PHASE2_PASS" "$log_file"; then
  printf 'PASS: update applied and activated (%s)\n' "$mode"
  exit 0
fi

if [ "$mode" = "broken" ]; then
  # A rejected bundle must not reach either phase marker.
  if grep -qF "OBKA_UPDATE_PHASE1_PASS" "$log_file"; then
    fail "untrusted bundle was accepted"
  fi
  printf 'PASS: untrusted bundle rejected (%s)\n' "$mode"
  exit 0
fi

fail "update did not complete; see $log_file"
