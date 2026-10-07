# verification

Reproducible, host-agnostic build environment and headless QEMU checks.

Build and verification are **decoupled**: the build emits a directory of
artifacts and verification consumes it. The build host never runs emulated
guests and needs no QEMU or OVMF.

## Architecture

The target architecture is chosen by `OBKA_ARCH` — `aarch64` by default on
arm64 hosts, `x86_64` otherwise. On a macOS arm64 host the aarch64 image is the
iteration target, booted under QEMU's `hvf` accelerator as a proxy for the real
arm64 board; x86_64 is built the same way and verified where it can run (an
x86_64 Linux/WSL host with KVM, or software emulation).

## Build environment

`build-env/` is a native (host-architecture) Debian container with the Buildroot
build dependencies and the disk tools (`gdisk`/`sgdisk`, `dosfstools` `mkfs.fat`,
`mtools`, `parted`, `e2fsprogs`, `openssl`, `rauc`, `squashfs-tools`). It does
**not** include QEMU or OVMF. Buildroot cross-compiles the target, so one host
builds any target without emulation.

```
image/verification/build.sh [arch] [outdir]
```

`build.sh` builds in the container and stages the artifact directory to
`dist/os/<arch>` (or `outdir`). Build knobs (`VERIFY*`, `BREAK`, `MAKE_DISK`,
`MAKE_INSTALLER`, `IMAGE_TAG`, `RAUC_SIGNING_*`, `RAUC_KEYRING`, ...) are
forwarded. Verification uses a small partition layout
(`image/os/partition-layout.verify.json`) so disk images stay storable; the
release build uses `image/os/partition-layout.json`.

A Linux host with the build dependencies can also run
`image/os/buildroot/build.sh` directly; `build.sh` detects Docker and otherwise
builds on the host.

## QEMU checks

All harnesses are headless (serial on stdio) and report a deterministic pass or
fail. They accept an optional architecture argument and use the host's fastest
accelerator (`hvf` on macOS, `kvm` on Linux, `tcg` otherwise).

```
image/verification/qemu/boot-test.sh dist/os/aarch64/disk-a.img OBKA_VERIFY_PASS
```

- `boot-test.sh <disk> [marker]` — boot under UEFI and assert a serial marker
  (default `OBKA_BOOT_OK`; a `VERIFY=1` image prints `OBKA_VERIFY_PASS`).
- `persist-test.sh [arch]` — writable-contract persistence across reboot and
  slot switch.
- `verify-test.sh [arch]` — the guest functional checks, plus one deliberately
  broken image per `BREAK` value (`ro`/`etc`/`var`/`user`) whose matching check
  must fail.
- `install-test.sh [installer] [size]` — install to a blank disk, then boot it.
- `reinstall-test.sh [arch]` — reinstall and assert the user partition is kept.
- `install-interactive-test.sh [arch]` — drive the console to select and confirm
  the target disk.
- `update-test.sh [good|broken] [arch]` — two-phase RAUC update apply/activate,
  or rejection of an untrusted bundle.
- `health-test.sh [pass|revert] [arch]` — health gate marks a healthy slot good,
  or reverts a persistently unhealthy update and restores configuration.
- `dev-vm.sh` — developer helper: build with an SSH key, install to a virtual
  disk, boot with SSH forwarded. See `../docs/dev-qemu.md`.
- `update-server.sh <bundle-dir> [port]` — development update service.

Common overrides: `OBKA_ARCH`, `OBKA_REBUILD=1`, `OBKA_ARTIFACTS`,
`OVMF_CODE`/`OVMF_VARS`, `BOOT_TIMEOUT`, `INSTALL_TIMEOUT`, and the `*_LOG`
paths.

### Functional checks

`guest/obake-verify.sh` runs inside a verification image (`VERIFY=1`) and checks
the writable contract: read-only root, the persistent `/etc` overlay, the `/var`
tmpfs with its persisted subset, the writable user partition, the pinned
Singularity CE runtime, the realtime kernel, and the RAUC/update wiring. It
prints one `OBKA_CHECK <name>=pass|fail` line per check and `OBKA_VERIFY_PASS`
or `OBKA_VERIFY_FAIL`.

`VERIFY=1` installs the checks; `BREAK=<behavior>` injects a fault so the suite
can prove the matching check fails:

| `BREAK` | Broken behavior              | Expected check failure     |
|---------|------------------------------|----------------------------|
| (unset) | none                         | `OBKA_VERIFY_PASS`         |
| `ro`    | root mounted read-write      | `root-readonly=fail`       |
| `etc`   | `/etc` overlay disabled      | `etc-overlay=fail`         |
| `var`   | `/var` not tmpfs             | `var-contract=fail`        |
| `user`  | `/home` not mounted          | `user-partition=fail`      |

## Reproducibility

The base is pinned by the Buildroot release and per-package versions and hashes
(`image/os/buildroot/pins.json`), so unchanged pins select the same package,
kernel, and runtime versions on any host. The canonical reproducible artifact is
the rootfs archive (`root-<slot>.tar`); the ext4 image is a derived boot
artifact. `verification/reproducibility.sh <platform>` records artifact digests.
