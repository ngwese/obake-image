# os

Image build for the obake host operating system.

The host image is built with Buildroot from a pinned release (see
`buildroot/`). The earlier layered Debian build is retained under this
directory until it is retired; it is documented at the end of this file.

## Buildroot build

### Layout

| Path                        | Purpose                                          |
|-----------------------------|--------------------------------------------------|
| `buildroot/external.desc`   | `BR2_EXTERNAL` tree identity                      |
| `buildroot/Config.in`       | external tree menu                                |
| `buildroot/configs/`        | board defconfigs (`obake_aarch64`, `obake_x86_64`)|
| `buildroot/board/obake/`    | kernel configs, realtime fragment, build hooks    |
| `buildroot/package/`        | in-tree packages (added by later changes)         |
| `buildroot/pins.json`       | pinned Buildroot release and kernel source        |
| `buildroot/build.sh`        | verified build wrapper                            |

Buildroot cross-compiles for the target and never executes target binaries, so
any Linux host architecture can build any target image; no emulation or binfmt
handler is required.

### Userland

The minimal base runs systemd and provides `bash`, `grep`, `vi`, `sudo`,
`systemctl`, `journalctl`, `dmesg`, `openssh`, and polkit. The `obake` login
user is created from `board/obake/users.txt` (password unset, so access is by
SSH key only), and the ported host configuration lives in
`board/obake/rootfs-overlay/`.

The packages the shapes build and run on form a separate **runtime layer**, a
`BR2_EXTERNAL` meta-package `obake-runtime` (`package/obake-runtime/Config.in`)
whose `select`s name the layer once so a defconfig reuses it. It currently
selects `obake-jack2`, `alsa-utils`, `usb-modeswitch`, `nftables`, `avahi`
(+ daemon), `nss-mdns`, `libcurl` (+ the `curl` binary), `iproute2`, `sudo`, and
`git`, and will select the Singularity runtime. Enable it with
`BR2_PACKAGE_OBAKE_RUNTIME=y`; `obake-jack2` additionally needs
`BR2_TOOLCHAIN_BUILDROOT_CXX=y` for target C++/libstdc++.

`obake-jack2` (`package/obake-jack2/`) is an external recipe that builds jack2
with `--alsa --classic --dbus`, installing both `jackd` and `jackdbus`. It
removes the Python `jack_control` helper and selects no Python interpreter or
bindings, so the host carries no Python runtime; drive `jackdbus` over its
D-Bus interface. Use it instead of the in-tree `BR2_PACKAGE_JACK2_DBUS`, which
selects Python solely for `jack_control`.

Because `jackdbus` is D-Bus activated, the overlay also provides a per-user
session bus for `obake`: the standard systemd user `dbus.socket`/`dbus.service`
units (Buildroot does not package them), enabled on the user manager, with the
manager started at boot by `obake-linger.service`. `org.jackaudio.service` is
then activatable on `unix:path=/run/user/<uid>/bus`, which the future
`obake-launcher` will use to activate and configure `jackd` over D-Bus.

`rtkit` is not included: Buildroot has no `rtkit` package, and realtime
scheduling and locked memory are provided by the `limits.d` grants and the
PREEMPT_RT kernel. Further meta-packages (developer tooling, audio-over-IP) are
left to later changes.

Two Buildroot options are easy to miss:

- `BR2_PACKAGE_SYSTEMD_POLKIT=y` makes systemd consult polkit; without it a
  non-root user is denied unit management even with a matching polkit rule.
  Selecting it also pulls in `BR2_PACKAGE_POLKIT`.
- `BR2_TARGET_ROOTFS_EXT2_SIZE` must be large enough for the systemd image
  (set to `1G` here).

Because the overlay is copied with the build user's ownership, `post-build.sh`
root-owns the ported configuration (polkit and sshd require it) and adds the
`Include /etc/ssh/sshd_config.d/*.conf` line the packaged `sshd_config` lacks.

### Pins

`buildroot/pins.json` is the single source of truth for the base:

- the Buildroot release (currently `2026.02.3`, the current LTS), with its
  tarball URL and SHA-256;
- the realtime kernel source (currently `7.2.9`), with its tarball URL and
  SHA-256.

`build.sh` verifies both hashes before building, so an unchanged `pins.json`
always selects the same base userland and kernel. Bumping either pin and
rebuilding is the only way the base changes.

Buildroot downloads every package from `sources.buildroot.net`
(`BR2_PRIMARY_SITE` in the defconfigs); hashes are still checked, so the mirror
is transport only. Set `DL_DIR` to a populated directory to build offline.

### Kernel

The realtime kernel is built from the pinned source with the board's base
config plus `board/obake/linux-realtime.fragment`. PREEMPT_RT has been part of
mainline since 6.12, so the fragment enables `CONFIG_PREEMPT_RT` and a 1000 Hz
tick without any out-of-tree patchset. `post-build.sh` records the built kernel
version under `/etc/obake/kernel` and refuses to produce an image whose kernel
is not realtime.

### Building

Run on a Linux host or inside a Linux container:

```
image/os/buildroot/build.sh obake_aarch64_defconfig
image/os/buildroot/build.sh obake_x86_64_defconfig
```

The wrapper downloads and verifies the pinned Buildroot release, seeds the
verified kernel tarball into Buildroot's download cache, then runs the build.
Extra arguments are passed to the final `make`, for example:

```
image/os/buildroot/build.sh obake_aarch64_defconfig -j"$(nproc)"
```

Environment overrides:

| Variable            | Default                         | Meaning                     |
|---------------------|---------------------------------|-----------------------------|
| `OBAKE_WORK`        | `image/.build/buildroot`        | source, download and output |
| `DL_DIR`            | `<OBAKE_WORK>/dl`               | Buildroot download cache    |
| `OBAKE_IMAGE_VERSION` | `buildroot/VERSION`           | version recorded in the image |

### Outputs

Images are emitted under `$OBAKE_WORK/output/<defconfig>/images/`:

- `Image` / `bzImage`, device trees, and the rootfs `rootfs.ext4` and
  `rootfs.tar`;
- `/etc/obake/kernel` and `/etc/obake/image-version` are baked into the rootfs.

Per-slot unified kernel images and signed, versioned artifacts are added by
later changes.

## Partition layout

`partition-layout.json` is the single source of truth for partition roles,
labels, and GPT type GUIDs. The installer and `scripts/make-disk.sh` read the
same file.

## Legacy Debian build

The following layered Debian build is retained until it is retired by the
`buildroot-base-image` change.

### Layer model

The image is built from ordered, independently replaceable layers. Rebasing on a
newer Debian release means bumping the base pin in `manifest.json` and
rebuilding; higher layers are untouched.

| Layer | Name     | Implementation                                        |
|-------|----------|-------------------------------------------------------|
| L1    | base     | minimal Debian trixie (`mmdebstrap --variant=minbase`)|
| L2    | kernel   | pinned PREEMPT_RT kernel (`os/layers/kernel`)          |
| L3    | tuning   | realtime limits, JACK/udev config, mount contract      |
| L4    | runtime  | Singularity CE built from source, pinned (`os/layers/runtime`) |
| L5    | board    | per-board tuning overlay (`os/boards/<board>`)         |

The base package set and every layer input are pinned in `manifest.json`:
the Debian suite and mirror, the kernel meta-package and version, and the
Singularity CE source release (URL + SHA-256). Each higher layer contributes a
package list (resolved from the manifest by `build.sh`) plus an `apply.sh` file
overlay and a `files/` tree.

`host/udev/*.rules` and `host/jack/*` are consumed by the tuning layer.

#### Building

Build inside the containerized environment so the same commands work on macOS
arm64 and Windows 11 WSL x86_64 (see `../verification/README.md`):

```
verification/build-env/run.sh os/build.sh
```

Environment overrides:

| Variable   | Default                          | Meaning                          |
|------------|----------------------------------|----------------------------------|
| `ARCH`     | `amd64`                          | target architecture (`amd64`/`arm64`) |
| `SLOT`     | `a`                              | root slot to build               |
| `BOARD`    | `generic`                        | board tuning overlay             |
| `VERSION`  | `0.0.0`                          | artifact version                 |
| `MAKE_DISK`| `0`                              | also emit a bootable `disk-<slot>.img` |
| `MAKE_INSTALLER` | `0`                        | also emit `installer.img` (see `../installer/README.md`) |

`SUITE` and `MIRROR` default to the pinned values in `manifest.json`.

Two boards share one base: building with `BOARD=generic` and `BOARD=rk35xx`
produces images that differ only in the board overlay.

#### Outputs

For a given architecture and slot, the build emits into `dist/os/<arch>/`:

- `root-<slot>.img` — ext4 root filesystem image, labeled per
  `partition-layout.json`
- `root-<slot>.tar` — reproducible rootfs layer archive (canonical
  byte-reproducible artifact)
- `obake-<slot>.efi` — unified kernel image (kernel + initrd + cmdline)
- `disk-<slot>.img` — optional bootable disk (ESP + both roots + persist + user)
- `installer.img` — optional headless installer medium
- `VERSION`, `SHA256SUMS`, `image-manifest.json`
- `*.sig` — detached signatures when `OBKA_SIGNING_KEY` is set

Signing and verification use `scripts/sign.sh` and
`scripts/verify-signature.sh`. With no key configured, only checksums are
written.

#### Verification

```
verification/build-env/run.sh bash -c 'MAKE_DISK=1 os/build.sh && verification/qemu/boot-test.sh dist/os/amd64/disk-a.img'
```
