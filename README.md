# obake-image

Host OS image subsystem for **obake**, a headless Linux server for running
user-defined audio effects and synthesis processes, plus sequencers, MIDI
processors, and generative control systems for MIDI and OSC.

| Path            | Purpose                                                  |
|-----------------|----------------------------------------------------------|
| `os/`           | Buildroot-based host image build (pinned base, boards, layers) |
| `installer/`    | Headless installer for the image                          |
| `host/`         | Host-level udev rules and JACK configuration for the target |
| `verification/` | Containerized build environment and QEMU verification     |
| `docs/`         | Image documentation ([`user-guide.md`](docs/user-guide.md) end-to-end, plus `os-update.md`, `host-config.md`, `dev-qemu.md`) |

This repository is consumed as the `image/` submodule of the top-level
`obake` repository.
