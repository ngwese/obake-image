# os

Image build for the obake host operating system.

## Layer model

The image is built from ordered, independently replaceable layers. Rebasing on a
newer Debian release means bumping the base pin and rebuilding; higher layers are
untouched.

| Layer | Name     | Contents                                                   |
|-------|----------|------------------------------------------------------------|
| L1    | base     | minimal Debian trixie (`mmdebstrap --variant=minbase`)     |
| L2    | kernel   | custom realtime kernel, packaged as a Debian package        |
| L3    | tuning   | realtime limits, JACK/udev configuration, systemd units     |
| L4    | runtime  | Apptainer built from source, pinned                         |
| L5    | board    | per-board tuning metapackage                                |

`host/udev/*.rules` and `host/jack/*` are consumed by the tuning layer.

## Outputs

For a given architecture and slot, the build emits into `dist/os/<arch>/`:

- `root-<slot>.img` — ext4 root filesystem image, labeled per
  `partition-layout.json`
- `obake-<slot>.efi` — unified kernel image (kernel + initrd + cmdline)
- `*.sig` — signatures over the artifacts

## Partition layout

`partition-layout.json` is the single source of truth for partition roles,
labels, and GPT type GUIDs. The installer reads the same file.

## Building

Build inside the containerized environment so the same commands work on macOS
arm64 and Windows 11 WSL x86_64 (see `../verification/README.md`):

```
verification/build-env/run.sh os/build.sh
```

Environment overrides:

| Variable | Default                          | Meaning               |
|----------|----------------------------------|-----------------------|
| `ARCH`   | `amd64`                          | target architecture   |
| `SUITE`  | `trixie`                         | Debian base suite     |
| `SLOT`   | `a`                              | root slot to build    |
| `VERSION`| `0.0.0`                          | artifact version      |
| `MIRROR` | `http://deb.debian.org/debian`   | apt mirror            |
