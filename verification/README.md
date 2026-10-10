# verification

Headless QEMU checks and reproducibility tooling. Build tooling lives in
`../build/`; this tree consumes the artifact directory the build emits.

Build and verification are **decoupled**: the build emits a directory of
artifacts and verification consumes it. The build host never runs emulated
guests and needs no QEMU or OVMF.

## Architecture

The target architecture is chosen by `OBKA_ARCH` — `aarch64` by default on
arm64 hosts, `x86_64` otherwise. On a macOS arm64 host the aarch64 image is the
iteration target, booted under QEMU's `hvf` accelerator as a proxy for the real
arm64 board; x86_64 is built the same way and verified where it can run (an
x86_64 Linux/WSL host with KVM, or software emulation). Harnesses map the arch
to the matching `generic-<arch>` board and build its `virtual` profile.

## Build environment

The build entry point and its container live under `../build/`:

```
image/build/build.sh <board> [profile] --installer|--update
image/build/build.sh --print-dir <board> [profile]
```

`build.sh` builds in the container (as the invoking user) and stages artifacts
under `image/_out/os/<board>/<profile>/<version>-<shortsha>[-dirty]/`. Exactly
one of `--installer` or `--update` is required. Build knobs (`VERIFY*`,
`BREAK`, `MAKE_DISK`, `MAKE_INSTALLER`, `IMAGE_TAG`, `RAUC_SIGNING_*`,
`RAUC_KEYRING`, ...) are forwarded and override product/profile defaults.
Verification uses a small partition layout
(`image/os/partition-layout.verify.json`) so disk images stay storable; the
release build uses `image/os/partition-layout.json`.

A Linux host with the build dependencies can also run
`image/os/buildroot/build.sh` directly; `image/build/build.sh` detects Docker
and otherwise builds on the host.

## Verification environment

The harnesses need QEMU, OVMF/EDK2, the disk tools, and `rauc`. A host that has
them runs the harnesses directly. A host without them (a bare WSL2 install, for
example) can run the same harnesses unchanged inside `verify-env/`, which
provides that toolchain natively and passes through KVM and the Docker socket so
a harness can still ask `build.sh` to build artifacts in the build container:

```
image/verification/verify-env/run.sh image/verification/qemu/boot-test.sh \
  "$(image/build/build.sh --print-dir generic-x86_64 virtual)/disk-a.img"
```

`verify-env/run.sh` runs as the invoking user so harness output is user-owned
and removable without elevated privileges. When `/dev/kvm` or
`/var/run/docker.sock` exist, it adds those paths' host owning groups so
accelerated QEMU and nested builds keep working. Prefer this wrapper over a
raw `docker run`. Reclaim leftover foreign-owned trees with
`image/verification/ensure-user-owned.sh` (underscore dirs and known legacy
paths under `verification/qemu/` such as `boot-test.log`, `install-test.log`,
and `install-work/`); `verify-env/run.sh` invokes that helper automatically.

Host prerequisites for containerized build and verification: Docker with the
Buildx CLI plugin (Ubuntu: `apt install docker-buildx`), a readable Docker
socket for nested builds, plus `/dev/kvm` for acceleration on Linux / WSL2.
Without Buildx the env wrappers fail immediately instead of using the legacy
builder.

Harness work and logs land under `image/_verify/` (user-owned); the developer
VM helper uses `image/_dev/` (also user-owned).

## QEMU checks

All harnesses are headless (serial on stdio) and report a deterministic pass or
fail. They accept an optional architecture argument and use the host's fastest
accelerator (`hvf` on macOS, `kvm` on Linux, `tcg` otherwise).

```
image/verification/qemu/boot-test.sh \
  "$(image/build/build.sh --print-dir generic-x86_64 virtual)/disk-a.img" \
  OBKA_VERIFY_PASS
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
- `integration-test.sh [arch]` — end-to-end: installer, customize, update,
  forced failed update, and revert, asserting reversion and that the user
  partition is unchanged.
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
(`image/os/buildroot/pins.json`), and the base defconfig enables
`BR2_REPRODUCIBLE` (fixed `SOURCE_DATE_EPOCH`, normalized paths/timezone), so
unchanged pins select the same package, kernel, and runtime versions and yield a
byte-identical rootfs archive. Each build emits `pinned-inputs.json` next to the
artifacts (embedded in `image-manifest.json`), recording the exact Buildroot,
kernel, runtime, and EFI-stub versions it used.

```
image/verification/reproducibility.sh [board]
```

builds the board twice with the same output directory (clean between) and the
frozen download cache, and asserts `root-a.tar` and `pinned-inputs.json` are
identical, writing a record to
`image/verification/reproducibility/<board>.sha256` and printing
`OBKA_REPRODUCIBLE_PASS`. On macOS it runs the builds in the native build
container.
