# obake-image

Host OS image subsystem for **obake**, a headless Linux server for running
user-defined audio effects and synthesis processes, plus sequencers, MIDI
processors, and generative control systems for MIDI and OSC.

| Path            | Purpose                                                  |
|-----------------|----------------------------------------------------------|
| `os/`           | Buildroot-based host image build (pinned base, boards, layers) |
| `build/`        | Containerized build entry point and build environment     |
| `installer/`    | Headless installer for the image                          |
| `host/`         | Host-level udev rules and PipeWire 1.6.10 / WirePlumber 0.5.18 configuration |
| `verification/` | QEMU verification, reproducibility, and update-server tooling |
| `docs/`         | Image documentation ([`user-guide.md`](docs/user-guide.md) end-to-end, plus `os-update.md`, `host-config.md`, `dev-qemu.md`) |

This repository is consumed as the `image/` submodule of the top-level
`obake` repository.

## Build

```
image/build/build.sh <board> [profile] --installer|--update
image/build/build.sh --print-dir <board> [profile]
```

`board` is `generic-aarch64`, `generic-x86_64`, `qdl`, or `rk35xx`. `profile`
is `default` (physical board; the default when omitted) or `virtual`
(emulation/verification). Exactly one product flag is required: `--installer`
for flash media, `--update` for signed RAUC bundles (default development
signing under `image/_build/signing`). The target architecture follows from
the board. Artifacts stage under
`image/_out/os/<board>/<profile>/<version>-<shortsha>[-dirty]/`.
