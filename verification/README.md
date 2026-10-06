# verification

Reproducible, host-agnostic build environment and headless QEMU checks.

## Build environment

`build-env/` is a Debian trixie container providing `mmdebstrap`, `ukify`,
`rauc`, QEMU, and OVMF, and building Singularity CE from source. It is pinned so
the same commands run on macOS arm64 and Windows 11 WSL x86_64.

The container is built and run as `linux/amd64` so x86_64 images build natively
inside it on both hosts (on macOS arm64 the container runs under emulation).

```
verification/build-env/run.sh os/build.sh
```

`run.sh` builds the container image, then runs the given command inside it with
the repository mounted at `/work`.

Environment overrides:

| Variable              | Default           | Meaning                        |
|-----------------------|-------------------|--------------------------------|
| `OBKA_BUILD_IMAGE`    | `obake-build-env` | container image tag            |
| `OBKA_BUILD_PLATFORM` | `linux/amd64`     | container platform             |

## Hardware acceleration

The QEMU harnesses auto-detect the best accelerator via `qemu/qemu-env.sh`:

| Host                    | Accelerator   | CPU    | Disk I/O                 |
|-------------------------|---------------|--------|--------------------------|
| Linux / WSL2 (nested)   | `kvm`         | `host` | `cache=none,aio=native`  |
| Windows-native QEMU     | `whpx`/`hax`  | `host` | `cache=none,aio=threads` |
| none available          | `tcg`         | `max`  | `cache=none,aio=threads` |

On Windows 11 WSL2, enable the "Virtual Machine Platform"/nested virtualization
so `/dev/kvm` exists; `build-env/run.sh` passes it to the container with
`--device /dev/kvm` automatically. All block devices are raw images attached
with `if=virtio`, the SMP topology is explicit
(`cores=,threads=1,sockets=1`), and the host CPU model is passed through
(`-cpu host`). The harnesses are headless (`-nographic`, serial on stdio), so no
GPU/QXL/SPICE device is configured.

Override with `OBKA_QEMU_ACCEL`, `OBKA_QEMU_CPU`, `OBKA_QEMU_CORES`,
`OBKA_QEMU_CACHE`, or `OBKA_QEMU_AIO` (e.g. `OBKA_QEMU_ACCEL=tcg` to force
software emulation, or `OBKA_QEMU_AIO=io_uring` where supported).

## QEMU checks

All scripts are headless (`-nographic`, serial on stdio) and report a
deterministic pass or fail by matching a marker in the captured serial log.

- `qemu/boot-test.sh <disk-image> [marker]` — boot a disk under OVMF and assert
  the marker appears. Default marker is `login:`.
- `qemu/install-test.sh <installer-image> [disk-size]` — create an empty virtual
  disk, run the installer, wait for `OBKA_INSTALL_DONE`, then boot the installed
  disk.
- `qemu/install-interactive-test.sh [arch]` — boot the installer with no
  preselected disk and drive the serial console to select and confirm the
  target.
- `qemu/reinstall-test.sh [arch]` — install, write a marker into the user
  partition, reinstall, and assert the user partition is preserved.
- `qemu/verify-test.sh [arch]` — build a good image and one broken per behavior,
  boot each, and assert the functional checks pass or fail as expected.
- `qemu/update-test.sh [good|broken|https|usb] [arch]` — build a signed RAUC
  bundle and a verification image carrying it, then boot twice with persistent
  EFI variables: phase 1 installs the bundle to the inactive slot and powers
  off, phase 2 asserts the update activated and reports the installed
  version/kernel. `broken` signs with an untrusted CA and asserts rejection;
  `https` fetches from `update-server.sh`; `usb` asserts USB is preferred.
- `qemu/health-test.sh [pass|revert] [arch]` — install a bundle and assert the
  health gate marks a healthy slot good, or reverts a persistently unhealthy one
  and restores its configuration.
- `qemu/persist-test.sh [arch]` — write markers under `/etc`, `/var`, and
  `/home`, then reboot and switch slots to assert the writable contract.
- `qemu/ssh-test.sh [arch]` — boot with an injected key and verify SSH access
  and the directory contract.
- `qemu/integration-test.sh [arch]` — full install → customize → update → reboot
  → forced failed update → revert on a target disk, asserting the writable
  contract and an unchanged user partition.
- `qemu/dev-vm.sh` — developer helper: build with an SSH key, install to a
  virtual disk, and boot it with SSH forwarded for inspection. See
  `../docs/dev-qemu.md`.
- `update-server.sh <bundle-dir> [port]` — development update service for a
  build host (HTTP, or HTTPS with `UPDATE_SERVER_TLS=1`).
- `build-singularity-stage.sh <version> <sha256> <dir>` — build a staged
  Singularity CE tree for the runtime layer (e.g. to ship a newer version in a
  bundle).

Common overrides: `BOOT_TIMEOUT`, `INSTALL_TIMEOUT`, `BOOT_MARKER`,
`INSTALL_MARKER`, `OVMF_CODE`, `OVMF_VARS`, and the `*_LOG` paths.

### Functional checks

`guest/obake-verify.sh` runs inside a verification image (`VERIFY=1`) and checks
the writable contract: read-only root, the persistent `/etc` overlay, the `/var`
tmpfs with its persisted subset, the writable user partition, the pinned
Singularity CE runtime, and the realtime kernel. It prints one
`OBKA_CHECK <name>=pass|fail` line per check and `OBKA_VERIFY_PASS` or
`OBKA_VERIFY_FAIL`, then powers the machine off.

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

Reproducibility across the two development hosts is tracked by per-platform
artifact digests. `verification/reproducibility.sh <platform>` builds the image
and records the digests of the reproducible artifacts — the rootfs tarballs
(`root-<slot>.tar`) and the per-slot UKIs — under `reproducibility/`:

```
verification/build-env/run.sh verification/reproducibility.sh wsl-x86_64
```

The ext4 root images (`root-<slot>.img`) are derived boot artifacts and are not
byte-for-byte reproducible because `mke2fs -d` is ordered by directory iteration
order; the tarball is the canonical reproducible layer artifact. The WSL x86_64
record is `reproducibility/wsl-x86_64.sha256`; the macOS arm64 record is
`reproducibility/macos-arm64.sha256` (task 1.2a), and task 1.2c compares them.
