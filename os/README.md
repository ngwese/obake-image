# os

Image build for the obake host operating system.

## Layer model

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

## Building

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

## Outputs

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

## Partition layout

`partition-layout.json` is the single source of truth for partition roles,
labels, and GPT type GUIDs. The installer and `scripts/make-disk.sh` read the
same file.

## Verification

```
verification/build-env/run.sh bash -c 'MAKE_DISK=1 os/build.sh && verification/qemu/boot-test.sh dist/os/amd64/disk-a.img'
```
