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
| `buildroot/configs/`        | shared base + per-board fragments (`obake_base`, `obake-<board>`) |
| `buildroot/board/obake/`    | kernel configs, fragments, per-board overlays, build hooks |
| `buildroot/package/`        | in-tree packages (added by later changes)         |
| `buildroot/pins.json`       | pinned Buildroot release and kernel source        |
| `buildroot/build.sh`        | verified build wrapper                            |

Buildroot cross-compiles for the target and never executes target binaries, so
any Linux host architecture can build any target image; no emulation or binfmt
handler is required.

### Boards

Every board is built from one shared base and differs only in its board
fragment and overlay, so adding or changing a board cannot fork the base. There
are four boards:

| Board             | Arch    | Base kernel config          | Purpose                    |
|-------------------|---------|-----------------------------|----------------------------|
| `generic-aarch64` | aarch64 | `generic-aarch64/linux.config` | QEMU `virt` proxy for arm64 |
| `generic-x86_64`  | x86_64  | `generic-x86_64/linux.config`  | development and CI hosts   |
| `qdl`             | x86_64  | `qdl/linux.config`             | MeLE Quieter DL (Intel N100) |
| `rk35xx`          | aarch64 | arm64 default config        | FriendlyElec RK3588 (NanoPC-T6) |

`build.sh` forms each board's defconfig as `configs/obake_base.config` followed
by `configs/obake-<board>.config`; the base holds the userland, systemd setup,
RAUC/obake packages, kernel version, fragments, and rootfs image settings, while
the board fragment holds only its arch, kernel config selection, board overlay,
and (for rk35xx) its bootloader. `buildroot/check-boards.sh` enforces that no
board fragment overrides a base symbol and prints how two boards differ.

`rk35xx` boots a Rockchip DDR + TF-A chain: the Rockchip DDR TPL (`rkbin`), TF-A
`bl31`, and mainline U-Boot (`nanopc-t6-rk3588_defconfig`, `u-boot-rockchip.bin`)
are written to the raw region before the first partition (the disk reserves the
first 16 MiB for it, `DISK_ALIGN_MIB=16`). U-Boot's EFI then loads the per-slot
UKI from the ESP with `console=ttyS2`. Only the build and the raw boot region
are verified here; the on-hardware boot path (DDR, peripheral, DTB bring-up) is
a hardware smoke test (see `design.md`).

### Userland

The minimal base runs systemd and provides `bash`, `grep`, `vi`, `sudo`,
`systemctl`, `journalctl`, `dmesg`, `openssh`, polkit, and a system CA trust
store (`ca-certificates`) so host TLS clients can verify HTTPS endpoints. The
`obake` login user is created from `board/obake/users.txt` (password field
`*`, so access is by SSH key only by default). Set `OBKA_PASSWORD` at build
time to hash a password into the image and enable SSH password authentication
as `obake` (image rootfs only; not seeded onto persist). The ported host
configuration lives in `board/obake/rootfs-overlay/`.

To trust a personal or self-signed root CA (for example a private container
registry), place PEM files named `*.crt` under
`buildroot/board/obake/extra-ca-certificates/` and rebuild. They are merged
into `/etc/ssl/certs/ca-certificates.crt` at build time. Do not put private
keys there; an empty directory is the default. RAUC's release keyring at
`/etc/rauc/ca.cert.pem` is separate and is not affected.

The packages the shapes build and run on form a separate **runtime layer**, a
`BR2_EXTERNAL` meta-package `obake-runtime` (`package/obake-runtime/Config.in`)
whose `select`s name the layer once so a defconfig reuses it. It currently
selects `obake-pipewire` (PipeWire 1.6.10), `obake-wireplumber` (WirePlumber
0.5.18), `alsa-utils`, `usb-modeswitch`, `nftables`, `avahi`
(+ daemon), `nss-mdns`, `libcurl` (+ the `curl` binary), `iproute2`, `sudo`,
`git`, and `obake-container`. Enable it with `BR2_PACKAGE_OBAKE_RUNTIME=y`.
The in-tree Buildroot `pipewire` and `wireplumber` packages stay unselected
so a Buildroot bump cannot change the audio versions. `BR2_TOOLCHAIN_BUILDROOT_CXX`
remains in the base defconfig; the audio recipes do not need it.

The container runtime is its own meta-package, `obake-container`
(`package/obake-container/`), which selects `package/singularity`
(SingularityCE, built from source via its `mconfig`/`makeit` build and the
Buildroot Go toolchain). It is pinned to **4.5.1** because 4.6.0 requires Go
>= 1.26.8 and Buildroot ships 1.26.3; revisit on a Go bump. Keeping it a
separate meta-package groups its large dependency tree (Go, gnupg2/gpgme,
cryptsetup, FUSE3, seccomp, squashfs tools) apart from the audio/network
runtime. Future changes add further meta-packages (developer tooling,
audio-over-IP) the same way.

`obake-pipewire` (`package/obake-pipewire/`) builds PipeWire **1.6.10** with
the daemon, the ALSA plugin, and `pipewire-jack`. The plugin that would make
PipeWire a client of `jackd` is disabled, and so is PulseAudio. There is no
`jackd` and no `jackdbus`. `obake-wireplumber` (`package/obake-wireplumber/`)
builds WirePlumber **0.5.18** against the system Lua interpreter, with
introspection disabled, so the host still has no Python runtime.
`rtkit` is not included: Buildroot has no `rtkit` package. Factory
`module.rt.args` drop-ins disable RTKit and the realtime portal for PipeWire
and WirePlumber. Realtime scheduling and locked memory for the audio daemons
come from the `pipewire.service` and `wireplumber.service` user-service
limits and the PREEMPT_RT kernel.

The image enables Linux-PAM (`BR2_PACKAGE_LINUX_PAM`), so systemd and OpenSSH
are built with PAM. Interactive SSH/login sessions run `pam_limits` and
`pam_systemd`: `@audio` rtprio 95 and unlimited memlock from
`/etc/security/limits.d/obake-audio.conf` apply to the login shell, and
`XDG_RUNTIME_DIR` / session-bus environment come from logind rather than a
`profile.d` workaround.

The overlay provides a per-user session bus for `obake`: the standard systemd
user `dbus.socket`/`dbus.service` units (Buildroot does not package them),
enabled on the user manager, with the manager started at boot by
`obake-linger.service`. That starts `pipewire.service` and
`wireplumber.service` for `obake`. The daemon socket is
`/run/user/<uid>/pipewire-0`.

Further meta-packages (developer tooling, audio-over-IP) are left to later
changes.

Buildroot options that are easy to miss:

- `BR2_PACKAGE_LINUX_PAM=y` turns on PAM in systemd and OpenSSH (`UsePAM
  yes`, `pam_systemd`, `pam_limits`). Without it, login shells ignore
  `limits.d` and need hand-rolled session env.
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

The base defconfig sets `BR2_REPRODUCIBLE` (fixed `SOURCE_DATE_EPOCH`,
normalized paths/timezone), so a rebuild from unchanged pins reproduces the
rootfs archive. Each build also emits `pinned-inputs.json` next to the artifacts
(`scripts/pinned-inputs.sh`, embedded in `image-manifest.json`) recording the
Buildroot release, kernel, runtime, and EFI-stub versions selected. See
`../verification/README.md` for the reproducibility check.

Buildroot downloads every package from `sources.buildroot.net`
(`BR2_PRIMARY_SITE` in the defconfigs); hashes are still checked, so the mirror
is transport only. Set `DL_DIR` to a populated directory to build offline.

### Kernel

The realtime kernel is built from the pinned source with the board's kernel
config plus two shared fragments: `board/obake/linux-realtime.fragment`
(PREEMPT_RT has been in mainline since 6.12, so it enables `CONFIG_PREEMPT_RT`
and a 1000 Hz tick with no out-of-tree patchset) and
`board/obake/linux-obake.fragment` (the loop/SquashFS/initrd/FAT/dm-verity and
writable-contract options the host needs). The generic boards use a full custom
config; `rk35xx` builds from the arm64 default config, which carries the
Rockchip SoC drivers. `post-build.sh` records the built kernel version under
`/etc/obake/kernel` and refuses to produce an image whose kernel is not
realtime.

`build.sh` passes `-<rev>-<board>` as the kernel `LOCALVERSION` make variable.
`<rev>` is the 1-based history index of that board's kernel configuration in
the image git tree: the same configuration keeps the same rev, and an
image-only commit does not change it. `<board>` is the board id
(`generic-x86_64`, `generic-aarch64`, `rk35xx`, `qdl`). `uname -r` looks like
`7.2.9-<rev>-generic-x86_64` or `7.2.9-<rev>-rk35xx`. Board `linux.config`
files leave `CONFIG_LOCALVERSION` empty so it is not prefixed again.

### OS identity

Images brand as **obake-os**: `/etc/os-release` has `NAME`/`ID=obake-os`.
`VERSION` is the release version from `buildroot/VERSION` (or
`OBAKE_IMAGE_VERSION`) and matches `/etc/obake/image-version`. `VERSION_ID`
is that version plus `-g<shortsha>[-dirty]` from the image git tree
(`-gnogit` when git metadata cannot be read), and
`PRETTY_NAME="obake-os <VERSION_ID>"`. The login banner (`/etc/issue`) is
`Welcome to obake-os`.

### Building

Run on a Linux host or inside a Linux container:

```
image/os/buildroot/build.sh generic-aarch64
image/os/buildroot/build.sh generic-x86_64
image/os/buildroot/build.sh qdl
image/os/buildroot/build.sh rk35xx
```

The wrapper composes the shared base with the board fragment, downloads and
verifies the pinned Buildroot release, seeds the verified kernel tarball into
Buildroot's download cache, then runs the build. Extra arguments are passed to
the final `make`, for example:

```
image/os/buildroot/build.sh generic-aarch64 -j"$(nproc)"
```

Environment overrides:

| Variable            | Default                         | Meaning                     |
|---------------------|---------------------------------|-----------------------------|
| `OBAKE_WORK`        | `image/_build/buildroot`        | source, download and output |
| `DL_DIR`            | `<OBAKE_WORK>/dl`               | Buildroot download cache    |
| `OBAKE_IMAGE_VERSION` | `buildroot/VERSION`           | version recorded in the image |

### Outputs

Images are emitted under `$OBAKE_WORK/output/<board>/images/`:

- `Image` / `bzImage`, device trees, and the rootfs `rootfs.ext4` and
  `rootfs.tar`;
- `/etc/obake/kernel` and `/etc/obake/image-version` are baked into the rootfs.

The `board/obake/post-image.sh` hook then emits, from `partition-layout.json`:

- `obake-<slot>.efi` — per-slot unified kernel images (`ukify`);
- `root-<slot>.img` / `root-<slot>.tar` — per-slot root artifacts;
- `disk-<slot>.img` — bootable disk for each active slot (`scripts/make-disk.sh`);
- `VERSION`, `SHA256SUMS`, `image-manifest.json`, `pinned-inputs.json`, and,
  when `OBKA_SIGNING_KEY` is set, `*.sig` (`scripts/sign.sh`);
- when RAUC signing material is set, `obake-<version>-<slot>.raucb` update
  bundles (prior-version `obake-*.raucb` leftovers are removed first).

`pinned-inputs.json` `image_version` uses the same resolution as
`/etc/obake/image-version` (`OBAKE_IMAGE_VERSION`, else the baked rootfs
value, else `buildroot/VERSION`).

`ukify` comes from `host-systemd`. The x86_64 build gets its systemd EFI stub
in-tree (`BR2_PACKAGE_SYSTEMD_BOOT`); the aarch64 stub is pinned in
`buildroot/vendor/efi-stub/` (`pins.json`).

## Partition layout

`partition-layout.json` is the single source of truth for partition roles,
labels, and GPT type GUIDs. The installer and `scripts/make-disk.sh` read the
same file.
