# installer

Headless installer for an obake host. Runs over a serial console or a text
console with an attached keyboard and monitor; it never requires a graphical
interface.

## Flow

1. Enumerate candidate disks and prompt for a destination.
2. Require explicit confirmation before any destructive action.
3. Apply the layout from `../os/partition-layout.json` (stable labels and GUIDs).
4. Create filesystems and write both root slots from `IMAGES_DIR`.
5. Install systemd-boot and the per-slot unified kernel images to the ESP.
6. Seed the persist partition (machine-id, SSH host keys, hostname, network
   configuration) and create the user partition.
7. Print `OBKA_INSTALL_DONE`, which the QEMU harness matches.

Partition devices are resolved relative to the selected target disk, not by
global labels, so an installer medium that itself carries `OBKA_*` partitions
cannot be confused with the target.

## Reinstall preserving user data

Re-running the installer against a disk that already has the stable layout
deletes and recreates the system partitions (ESP, both roots, persist) and
leaves the user partition and its contents intact. Set `PRESERVE_USER=0` to
reformat the user partition as well.

## Installer image

`os/build.sh` emits the installer medium as `dist/os/<arch>/installer.img` when
`MAKE_INSTALLER=1` is set. It bundles the built per-slot images under
`/opt/obake/images` and runs `install.sh` at boot via
`obake-installer.service`. The medium uses its own partition labels
(`OBKA_INSTALLER`, `OBKA_INST`) and its own UKI, so a disk-based installer
cannot be confused with the target it is installing to. By default it targets
the second disk (`/dev/vdb`) and powers off when finished; set
`INSTALLER_TARGET_DISK=interactive` to prompt on the console instead. Build it
with:

```
verification/build-env/run.sh bash -c 'MAKE_INSTALLER=1 os/build.sh'
verification/build-env/run.sh verification/qemu/install-test.sh dist/os/amd64/installer.img
```

The interactive and reinstall flows are verified by
`verification/qemu/install-interactive-test.sh` and
`verification/qemu/reinstall-test.sh`.

## Usage

```
verification/build-env/run.sh installer/install.sh
```

Overrides:

| Variable        | Default                       | Meaning                       |
|-----------------|-------------------------------|-------------------------------|
| `TARGET_DISK`   | unset (interactive prompt)    | destination block device      |
| `IMAGES_DIR`    | `<repo>/dist/os/amd64`        | per-slot artifacts to write   |
| `ACTIVE_SLOT`   | `a`                           | slot to boot by default       |
| `PRESERVE_USER` | `1`                           | keep an existing user partition |
| `LAYOUT`        | `<repo>/os/partition-layout.json` | layout metadata           |
