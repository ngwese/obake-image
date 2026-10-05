# installer

Headless installer for an obake host. Runs over a serial console or a text
console with an attached keyboard and monitor; it never requires a graphical
interface.

## Flow

1. Enumerate candidate disks and prompt for a destination.
2. Require explicit confirmation before any destructive action.
3. Apply the layout from `../os/partition-layout.json` (stable labels and GUIDs).
4. Create filesystems and write both root slots from `dist/os/<arch>/`.
5. Install systemd-boot and the per-slot unified kernel images to the ESP.
6. Seed the persist partition (machine-id, SSH host keys, hostname) and create
   the user partition.
7. Print `OBKA_INSTALL_DONE`, which the QEMU harness matches.

The layout file is the single source of truth shared with the image build, so
partition roles, labels, and GUIDs cannot drift between them.

## Reinstall preserving user data

Re-running the installer against a disk that already has the stable layout
recreates the system partitions (ESP, both roots, persist) and leaves the user
partition and its contents intact.

## Usage

```
verification/build-env/run.sh installer/install.sh
```

Overrides: `TARGET_DISK` (skip the prompt), `IMAGES_DIR` (default
`dist/os/amd64`), `ACTIVE_SLOT` (default `a`).
