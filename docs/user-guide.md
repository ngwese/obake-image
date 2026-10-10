# obake-image user guide

End-to-end guide to building, verifying, installing, and updating the obake
host operating system. Start here; each chapter links to the subsystem
reference that owns the detail.

- [1. Orientation](#1-orientation)
- [2. Build system structure](#2-build-system-structure)
- [3. Building an image](#3-building-an-image)
- [4. What QEMU verifies, and what only hardware can](#4-what-qemu-verifies-and-what-only-hardware-can)
- [5. Installing on bare metal (x86_64 / qdl)](#5-installing-on-bare-metal-x86_64--qdl)
- [6. SSH access](#6-ssh-access)
- [7. Filesystem layout: read-only root vs writable contract](#7-filesystem-layout-read-only-root-vs-writable-contract)
- [8. Updating over USB](#8-updating-over-usb)

## 1. Orientation

The host OS subsystem lives under `image/` in the top-level obake repository
(it is published as the `obake-image` repository):

| Path            | Purpose                                                   |
|-----------------|-----------------------------------------------------------|
| `os/`           | Buildroot image build (pinned base, boards, runtime)      |
| `build/`        | Containerized build entry point and build environment     |
| `installer/`    | Headless installer for the image                          |
| `host/`         | Host-level udev rules and JACK configuration for the target |
| `verification/` | QEMU verification, reproducibility, and update-server tooling |
| `docs/`         | This guide and the subsystem references                   |

The lifecycle is a straight line:

```
   build                    install                  update
+----------+   artifacts   +---------+   running   +----------+
| os build | ------------> | USB     | ----------> | A/B slot |
| (pinned) |  disk/install | medium  |   host      | update   |
+----------+   images      +---------+             +----------+
     |                          |                         |
     v                          v                         v
  QEMU gate             bare metal / VM          USB bundle or HTTPS
```

- Chapter 2-3 build the artifacts.
- Chapter 4 states what the QEMU gate proves before hardware is involved.
- Chapter 5 installs a built image onto a bare-metal board.
- Chapters 6-8 cover day-two operation of an installed host.

The subsystem reference documents are authoritative for their areas:
`../os/README.md` (build), `../build/` (containerized entry point),
`../installer/README.md` (install), `../verification/README.md` (harnesses),
`host-config.md` (filesystem contract), `os-update.md` (updates), and
`dev-qemu.md` (a QEMU/KVM walkthrough).

## 2. Build system structure

The image is built with Buildroot from a single pinned external tree,
`os/buildroot/`:

| Path                       | Purpose                                           |
|----------------------------|---------------------------------------------------|
| `buildroot/external.desc`  | `BR2_EXTERNAL` tree identity                       |
| `buildroot/configs/`       | shared base plus per-board fragments              |
| `buildroot/board/obake/`   | kernel configs, fragments, overlays, build hooks  |
| `buildroot/package/`       | in-tree packages and meta-packages                |
| `buildroot/pins.json`      | pinned Buildroot release and kernel source        |
| `buildroot/profiles/`      | per-board `default` / `virtual` installer defaults |
| `buildroot/build.sh`       | low-level build wrapper                           |

Every board is built from one shared base, `configs/obake_base.config`,
combined with a board fragment, `configs/obake-<board>.config`. The base holds
the userland, systemd setup, runtime packages, kernel version, fragments, and
rootfs settings; the board holds only its architecture, kernel config
selection, overlay, and (for `rk35xx`) its bootloader. Adding a board cannot
fork the base.

| Board             | Arch    | Purpose                                  |
|-------------------|---------|------------------------------------------|
| `generic-aarch64` | aarch64 | QEMU `virt` proxy for arm64              |
| `generic-x86_64`  | x86_64  | development and CI hosts                 |
| `qdl`             | x86_64  | MeLE Quieter DL (Intel N100), bare metal |
| `rk35xx`          | aarch64 | FriendlyElec RK3588 (NanoPC-T6)          |

`buildroot/pins.json` is the single source of truth for the base: the Buildroot
release and the realtime kernel source, each with a SHA-256 that `build.sh`
verifies before building. Bumping a pin and rebuilding is the only way the base
changes. The base defconfig sets `BR2_REPRODUCIBLE`, so a rebuild from
unchanged pins reproduces the rootfs archive.

The userland packages are grouped into `BR2_EXTERNAL` meta-packages:
`obake-runtime` selects the audio and network runtime (`obake-jack2`,
`alsa-utils`, `avahi`, `nftables`, `libcurl`, `git`, and more), and
`obake-container` selects the Singularity CE runtime built from source. Future
layers are added the same way. The realtime kernel is built from the pinned
source with a shared realtime fragment (`PREEMPT_RT`, 1000 Hz tick) and a
host fragment (loop/SquashFS/initrd/FAT/dm-verity and the writable-contract
options). Board configs add a `CONFIG_LOCALVERSION` suffix (`-qdl`,
`-generic`; `rk35xx` none yet) and the build appends `-g<shortsha>[-dirty]`
from the image git tree, so `uname -r` identifies board and revision.

The running image presents as **obake-os** in `/etc/os-release` and greets
with `Welcome to obake-os` at login (`/etc/issue`). `VERSION` matches
`/etc/obake/image-version` (from `os/buildroot/VERSION`).

Buildroot cross-compiles and never executes target binaries, so any Linux host
can build any target image without emulation. See `../os/README.md` for the
full package and kernel detail.

## 3. Building an image

The recommended path runs inside the containerized, host-native build
environment and stages the artifacts under `image/_out/`:

```
image/build/build.sh <board> [profile] --installer|--update
image/build/build.sh --print-dir <board> [profile]
```

`board` is `generic-aarch64`, `generic-x86_64`, `qdl`, or `rk35xx`. The target
architecture follows from the board. `profile` is `default` (physical board;
used when omitted) or `virtual` (emulation/verification). Exactly one product
flag is required: `--installer` for flash media, `--update` for signed RAUC
bundles. Each board's profile under `os/buildroot/profiles/<board>/` supplies
console and target-disk defaults; an explicit setting still wins.
(`CONSOLE` was formerly `INSTALLER_CONSOLE`.) Unset signing paths default to
development material under `image/_build/signing` (created if missing).

```
# generic x86_64 update bundles (both profiles are equivalent)
image/build/build.sh generic-x86_64 --update

# the MeLE Quieter DL board, bare-metal installer (local console, interactive disk)
image/build/build.sh qdl --installer

# the same board for QEMU (serial console, /dev/vdb)
image/build/build.sh qdl virtual --installer
```

On a Linux host with the build dependencies you can run the low-level wrapper
directly:

```
image/os/buildroot/build.sh <board> [make-args...]
OBAKE_PROFILE=default image/os/buildroot/build.sh qdl -j"$(nproc)"
```

`build.sh` composes the defconfig, applies the profile, verifies and seeds the
pinned inputs, then builds. Both wrappers forward the build knobs
(`MAKE_INSTALLER`, `MAKE_DISK`, `CONSOLE`, `INSTALLER_TARGET_DISK`,
`RAUC_SIGNING_*`, `OBKA_SSH_AUTHORIZED_KEY`, `OBKA_PASSWORD`, and the
verification `VERIFY*`/`BREAK` switches).

Images are staged under
`image/_out/os/<board>/<profile>/<version>-<shortsha>[-dirty]/` (containerized
path) or left in the Buildroot work tree under `image/_build/`
(`$OBAKE_WORK/output/<board>/images/`, direct path). The build prints each
`artifact: <path>` when it finishes:

| Artifact                         | Meaning                                   |
|----------------------------------|-------------------------------------------|
| `<kernel>` (`bzImage`/`Image`)   | kernel                                    |
| `rootfs.ext4`, `rootfs.tar`      | canonical root filesystem                 |
| `obake-<slot>.efi`               | per-slot unified kernel image (UKI)       |
| `root-<slot>.img`, `root-<slot>.tar` | per-slot root artifacts                |
| `disk-<slot>.img`                | bootable disk for a slot                  |
| `installer-<console>.img`        | installer medium, when `MAKE_INSTALLER=1` |
| `VERSION`, `SHA256SUMS`, `image-manifest.json`, `pinned-inputs.json` | version, hashes, inputs |
| `*.raucb`                        | signed update bundle from `--update`      |

The `../os/README.md` "Outputs" section lists the signing and disk assembly
scripts (`make-disk.sh`, `make-bundle.sh`, `sign.sh`).

## 4. What QEMU verifies, and what only hardware can

QEMU is the release gate for behavior that does not depend on physical
hardware. The harnesses under `../verification/qemu/` boot UEFI firmware
headlessly (serial on stdio) and report a deterministic pass or fail.

**What QEMU verifies**

| Behavior                                   | Harness                    |
|--------------------------------------------|----------------------------|
| Boots the active slot under UEFI           | `boot-test.sh`             |
| Installer runs against a blank disk, then the installed host boots | `install-test.sh` |
| Interactive disk selection and confirmation | `install-interactive-test.sh` |
| Reinstall preserves the user partition     | `reinstall-test.sh`        |
| Read-only root and writable contract across reboot and slot switch | `persist-test.sh` |
| Guest functional checks (contract, runtime, realtime kernel, RAUC wiring) | `verify-test.sh`, `guest/obake-verify.sh` |
| Signed update applies and activates; untrusted bundle rejected | `update-test.sh` |
| Health gate marks good or reverts and restores configuration | `health-test.sh` |
| End-to-end install, customize, update, forced failure, revert | `integration-test.sh` |
| SSH login, directory contract, privileged access | `ssh-test.sh` |
| Optional build-time password SSH login | `password-test.sh` |

Run one with an existing artifact, for example:

```
image/verification/qemu/boot-test.sh \
  "$(image/build/build.sh --print-dir generic-x86_64 virtual)/disk-a.img" \
  OBKA_VERIFY_PASS
```

**What QEMU cannot verify** (validate on real hardware instead):

- The Rockchip boot chain for `rk35xx`: DDR/TPL, TF-A BL31, and U-Boot
  bring-up before the first partition.
- Peripheral and driver bring-up on a specific board, including RTL8125
  ethernet (`r8169`) and USB MIDI 2.0 (UMP) on `qdl`.
- The firmware graphics path: the UEFI GOP framebuffer and the local text
  console that renders the installer on a monitor.
- Real storage device names and the physical medium, which is why the target
  disk must be selected (chapter 5).

These are covered by smoke tests on the target board, not by the automated
gate. `../os/README.md` and `../verification/README.md` note which checks are
hardware-only.

## 5. Installing on bare metal (x86_64 / qdl)

This chapter covers the supported bare-metal path: a UEFI x86_64 board such as
the MeLE Quieter DL (`qdl`). The `rk35xx`/arm64 board is **out of scope here**:
its installed disk carries a Rockchip raw boot region, but the installer medium
does not, so booting the installer from USB on that board is unverified.

The installer is headless and prompts over a serial console or a local text
console. For a hands-on virtual walkthrough instead of hardware, see
`dev-qemu.md`.

### 5.1 Gather before you start

Have these ready before building or installing:

| Item             | What to determine                                        |
|------------------|----------------------------------------------------------|
| Board            | `qdl` for the MeLE Quieter DL (x86_64)                   |
| Console          | `local` (HDMI monitor + USB keyboard; the `qdl` board has no serial port) or `serial` |
| Destination disk | the device name of the disk to install onto — for example `/dev/nvme0n1` (NVMe) or `/dev/sda` (SATA/USB) |
| SSH key          | a public key to seed, or decide to add one later (chapter 6) |

Find the destination device name on a running Linux host by plugging in the
target disk and inspecting it; the installer does not guess:

```
lsblk -dno NAME,SIZE,TYPE
```

The installer's built-in default is `/dev/vdb`, which is a QEMU name. On bare
metal you must override it with `INSTALLER_TARGET_DISK` (build time) or
`TARGET_DISK` (install time), or build with `INSTALLER_TARGET_DISK=interactive`
to select and confirm on the console. Selecting the wrong disk destroys it —
confirm the device name.

### 5.2 Build the installer medium

The `qdl` `default` profile already selects a local-console, interactive-disk
installer, so a bare-metal medium is:

```
image/build/build.sh qdl --installer
```

The medium lands at
`image/_out/os/qdl/default/<version>-<shortsha>[-dirty]/installer-local.img`
(the build prints the exact path). `CONSOLE` accepts `serial` or `local` and
applies to both the installer medium and the installed OS UKIs; `local` runs
the installer on `tty1` and adds `console=tty0` to the installer and OS
command lines, keeping the serial console as a fallback. Passing
`OBKA_SSH_AUTHORIZED_KEY=/path/to/id.pub` here bakes the public key into the
medium.

### 5.3 Write it to a USB device

Identify the USB device (not a partition), then write the raw image to it.
This erases the device:

```
lsblk -dno NAME,SIZE,TYPE
sudo dd if="$(image/build/build.sh --print-dir qdl)/installer-local.img" \
  of=/dev/sdX bs=4M conv=fsync status=progress
```

`/dev/sdX` is the whole USB device, not `/dev/sdX1`.

### 5.4 Boot and select the target disk

1. Insert the USB device and the destination disk, then boot the board from
   USB (firmware boot menu).
2. The installer enumerates candidate disks and prompts, for example:

   ```
   select destination disk:
   DESTROY /dev/nvme0n1 and install obake? [y/N]
   ```

   Enter the whole-device path and confirm with `y`.
3. It applies the shared partition layout, writes both root slots and the
   per-slot UKIs, seeds the persist partition, creates the user partition,
   then prompts you to press Enter before powering off.

Non-interactive builds skip the disk prompt and target `INSTALLER_TARGET_DISK`
directly, wait `INSTALLER_POWEROFF_DELAY` seconds (default 10; use `0` in CI),
then power off. Watch the console for `OBKA_INSTALL_DONE` and
`OBKA_INSTALL_EXIT=0` to confirm success.

Re-running the installer against an existing obake disk recreates the system
partitions and keeps the user partition; `PRESERVE_USER=0` reformats the user
partition too. See `../installer/README.md` for the installer's variables and
the reinstall behavior.

## 6. SSH access

By default the `obake` login user has no password; access is by SSH key.
Authorized keys are read from `/etc/ssh/authorized_keys.d/obake`.

Generate a key on your workstation and keep the private half where you
generated it:

```
ssh-keygen -t ed25519 -f ~/.ssh/obake_id
# public:  ~/.ssh/obake_id.pub   (seeded onto the host)
# private: ~/.ssh/obake_id       (stays on your workstation)
```

Seed the **public** key by pointing `OBKA_SSH_AUTHORIZED_KEY` at it:

- at build time, it is installed into the image at
  `/etc/ssh/authorized_keys.d/obake`;
- at install time, `install.sh` copies it onto the persist partition, so it
  survives updates and slot switches.

```
OBKA_SSH_AUTHORIZED_KEY="$HOME/.ssh/obake_id.pub" \
  image/build/build.sh qdl --installer
```

Then log in as `obake` once the host is on the network.

Optionally set a build-time password with `OBKA_PASSWORD`. When non-empty, the
image hashes it into the `obake` account and enables SSH password
authentication as `obake` (local console login uses the same password). The
hash lives only in the image rootfs — not on the persist partition — so an
OTA/slot switch replaces it with whatever the new image carries. Anyone with
the image artifact can offline-attack the hash; treat it as a shared device
secret, not a high-value credential, and do not commit the cleartext.

```
OBKA_PASSWORD='choose-a-secret' \
  OBKA_SSH_AUTHORIZED_KEY="$HOME/.ssh/obake_id.pub" \
  image/build/build.sh qdl --installer
```

There is **no SSH keypair generated at build time** — the build consumes a
public key you supply, and the private half never leaves your workstation. (The
only keypair the tooling generates is the RAUC signing material used to sign
update bundles, via `os/scripts/make-signing-material.sh`; that is unrelated to
login.) SSH *host* keys (the server identity) are generated at install time and
seeded onto the persist partition.

Once connected, the `obake` user can manage systemd units and power state and
read `dmesg` and the full journal without a password, and has passwordless sudo
for all commands (including `sudo -s` and `obake-update`). Without sudo, writes
to `/etc` and the read-only root still fail. Home data lives under
`/home/obake`. The root account is locked (no empty-password `su -`); escalate
with sudo instead. Singularity shapes run as `obake` via the setuid helper with
kernel SquashFS mounts (low-overhead SIF rootfs). On-device
`singularity build --fakeroot` / `exec --fakeroot` is supported (`/etc/subuid`
and `/etc/subgid` are seeded for `obake`); current shape `.def` files still use
`Bootstrap: docker` and may need network pull beyond fakeroot. See
`host-config.md`.

## 7. Filesystem layout: read-only root vs writable contract

The operating system root is mounted read-only; every allowed customization
lives in a named, persistent location backed by the persist or user partition.

| Path        | Backing                        | Persists across         |
|-------------|--------------------------------|-------------------------|
| `/` (root)  | read-only slot                 | replaced by an update   |
| `/etc`      | overlay upper on `/persist`    | boot, slot switch       |
| `/var`      | tmpfs, with a persisted subset | boot, slot switch for the subset |
| `/media`    | tmpfs (removable mount root)   | nothing (discarded)     |
| `/home`     | `OBKA_USER` partition          | updates, reinstalls     |
| `/persist`  | `OBKA_PERSIST` partition       | boot, slot switch       |

A write outside the contract fails because the root is read-only. `/persist`
holds the `/etc` overlay, the persisted `/var` subset, RAUC slot state, and the
machine-specific seed written at install time. Full detail, including the
persisted `/var` list and the exact partition roles, is in `host-config.md`.

The partition layout itself (`OBKA_ESP`, `OBKA_ROOT_A`, `OBKA_ROOT_B`,
`OBKA_PERSIST`, `OBKA_USER`) is defined once in `../os/partition-layout.json`
and shared by the installer and the disk builder.

## 8. Updating over USB

Updates are user-initiated, signed RAUC bundles. The signature is verified
against the project keyring before any slot is written, so the transport does
not matter: a bundle on a USB drive is as trustworthy as one fetched over
HTTPS, and USB is preferred when present. Updates write the inactive slot (and
its UKI) and take effect on the next boot; a failed update reverts
automatically.

1. **Sign a bundle.** Build with `--update` (development signing under
   `image/_build/signing` is created when unset), or pass explicit keys:

   ```
   image/build/build.sh generic-x86_64 --update
   # or:
   RAUC_KEYRING=image/_build/signing/ca.cert.pem \
   RAUC_SIGNING_CERT=image/_build/signing/signing.cert.pem \
   RAUC_SIGNING_KEY=image/_build/signing/signing.key \
     image/build/build.sh generic-x86_64 --update
   ```

   Run from the repo root. `image/build/build.sh` resolves those paths for
   the build container.

2. **Copy the bundle to the USB drive.** Place the `*.raucb` file at the root
   of any partition, or one directory deep. FAT/FAT32 and exFAT are supported.
   When the stick is attached, it auto-mounts for `obake` at `/media/<label>`
   (filesystem label, or a stable fallback if unlabeled). `/media` is a
   volatile tmpfs mount root on the read-only image; do not create mountpoints
   by hand on the slot root.

3. **Apply it on the host.**

   ```
   obake-update status     # running version, active slot, pending/activated
   obake-update apply      # /media USB preferred, then the HTTPS endpoint
   obake-update rollback
   ```

   `apply` and `rollback` need root (persist health state, RAUC). Those commands
   re-exec via `sudo` when run as `obake`; the image grants passwordless sudo
   for all commands (including `sudo -s`). Removable media does not require
   `mount`/`umount` in sudoers.

`apply` snapshots the shape configuration, writes the inactive slot, and marks
the update pending; a health gate marks it good after a successful boot or
reverts it after the configured number of attempts. The active slot is never
modified. The complete model — bundle format, signing, the HTTPS source,
health gate, and RAUC configuration — is in `os-update.md`.

## See also

- `../os/README.md` — build system, boards, pins, kernel, outputs
- `../installer/README.md` — installer flow, console selection, bare metal
- `../verification/README.md` — build environment and QEMU harnesses
- `dev-qemu.md` — build, install, and SSH into a QEMU/KVM host
- `host-config.md` — read-only root and the writable contract
- `os-update.md` — signed A/B updates, USB and HTTPS, health gate
