# verification

Reproducible, host-agnostic build environment and headless QEMU checks.

## Build environment

`build-env/` is a Debian trixie container providing `mmdebstrap`, `ukify`,
`rauc`, QEMU, and OVMF. It is pinned so the same commands run on macOS arm64 and
Windows 11 WSL x86_64.

The container is built and run as `linux/amd64` so x86_64 images build natively
inside it on both hosts (on macOS arm64 the container runs under emulation).

```
verification/build-env/run.sh os/build.sh
verification/build-env/run.sh verification/qemu/install-test.sh dist/os/amd64/installer.img
```

Environment overrides:

| Variable              | Default         | Meaning                        |
|-----------------------|-----------------|--------------------------------|
| `OBKA_BUILD_IMAGE`    | `obake-build-env` | container image tag          |
| `OBKA_BUILD_PLATFORM` | `linux/amd64`   | container platform             |

## QEMU checks

Both scripts are headless (`-nographic`, serial on stdio) and report a
deterministic pass or fail by matching a marker in the captured serial log.

- `qemu/boot-test.sh <disk-image> [marker]` — boot a disk under OVMF and assert
  the marker appears. Default marker is `login:`.
- `qemu/install-test.sh <installer-image> [disk-size]` — create an empty virtual
  disk, run the installer, wait for the `OBKA_INSTALL_DONE` marker, then boot the
  installed disk.

Common overrides: `BOOT_TIMEOUT`, `INSTALL_TIMEOUT`, `BOOT_MARKER`,
`INSTALL_MARKER`, `OVMF_CODE`, `OVMF_VARS`, and the `*_LOG` paths.

## Functional checks

After boot, the harness exercises the host over the serial console: the
read-only root, the writable contract, and an update apply and revert. These
checks live alongside the scripts and are wired into `install-test.sh` as they
are implemented.
