# installer

Headless installer for an obake host. Runs over a serial console or a text
console with an attached keyboard and monitor; it never requires a graphical
interface.

The installer medium is built by the Buildroot build
(`image/os/buildroot/board/obake/make-installer.sh`) when the selected board
profile (or an explicit `MAKE_INSTALLER=1`) requests it, and bundles the
per-slot images and UKIs. `install.sh` needs no Python on the target (it sources
the generated `partition-layout.env`). Verified headlessly by
`image/verification/qemu/install-test.sh`, `install-interactive-test.sh`, and
`reinstall-test.sh`.

## Flow

1. Enumerate candidate disks and prompt for a destination.
2. Require explicit confirmation before any destructive action.
3. Apply the layout from `../os/partition-layout.json` (stable labels and GUIDs).
4. Create filesystems and write both root slots from `IMAGES_DIR`.
5. Install the per-slot unified kernel images to the ESP and reconcile one
   active EFI boot entry per slot (`A` and `B`) on that ESP, with the
   install's active slot first. A reinstall leaves a single pair.
6. Seed the persist partition's `/etc` overlay (machine-id, SSH host keys,
   hostname, network configuration) and create the user partition.
7. Print `OBKA_INSTALL_DONE`, which the QEMU harness matches.

Partition devices are resolved relative to the selected target disk, not by
global labels, so an installer medium that itself carries `OBKA_*` partitions
cannot be confused with the target.

## Host name

`OBKA_HOSTNAME` seeds the installed host name (default `obake`, validated as an
RFC1123 name). The build carries it in the installer medium like the SSH key
seed. An interactive install prompts on the console with the seed as the
default; a non-interactive install uses the seed silently. The chosen name is
written into the persist `/etc` overlay and survives updates and slot switches.
The `obake` user can change it later without sudo with
`hostnamectl set-hostname <name>`.

## SSH access

Set `OBKA_SSH_AUTHORIZED_KEY` to a public key file when building or installing
to seed it for the `obake` user. The build carries the key as a seed in the
installer medium (and in a `MAKE_DISK` disk image); `install.sh` writes it to
`~/.ssh/authorized_keys` on the user partition, owned by `obake`, only when the
user has no key, so a reinstall that preserves user data never overwrites a
user-managed key. The installed host is then reachable over SSH and the user
can replace the key without sudo. For a hands-on QEMU/KVM walkthrough (set up a
VM, install, and log in), see `../docs/dev-qemu.md`.

## Reinstall preserving user data

Re-running the installer against a disk that already has the stable layout
deletes and recreates the system partitions (ESP, both roots, persist) and
leaves the user partition and its contents intact. Set `PRESERVE_USER=0` to
reformat the user partition as well.

## Board profiles

Installer defaults live in `image/os/buildroot/profiles/<board>/`:

| Board / profile              | `MAKE_INSTALLER` | Console  | Target disk   |
|------------------------------|------------------|----------|---------------|
| `generic-*` `default`/`virtual` | `0`           | serial   | `/dev/vdb`    |
| `qdl` `default`              | `1`              | local    | interactive   |
| `qdl` `virtual`              | `1`              | serial   | `/dev/vdb`    |
| `rk35xx` both                | `0`              | serial   | `/dev/vdb`    |

An explicit `MAKE_INSTALLER` / `CONSOLE` / `INSTALLER_TARGET_DISK`
still overrides the profile. (`CONSOLE` was formerly `INSTALLER_CONSOLE`.)
The bare-metal `qdl` flow is therefore:

```
image/build/build.sh qdl --installer
```

## Installer image

`image/build/build.sh … --installer` emits the installer medium at
`image/_out/os/<board>/<profile>/<version>-<sha>[-dirty]/installer-<console>.img`,
where `<console>` is `serial` or `local` (see Console selection below). It
bundles the built per-slot images under `/opt/obake/images` and runs
`install.sh` at boot via `obake-installer.service`. The medium uses its own
partition labels (`OBKA_INSTALLER`, `OBKA_INST`) and its own UKI, so a
disk-based installer cannot be confused with the target it is installing to.
By default the `virtual` profile targets the second disk (`/dev/vdb`) and
powers off when finished; set `INSTALLER_TARGET_DISK=interactive` to prompt on
the console instead. After install (success or failure), interactive media
prompt for Enter before poweroff; non-interactive media wait
`INSTALLER_POWEROFF_DELAY` seconds (default 10; set `0` for CI). Build and
verify a serial installer with:

```
INSTALLER_POWEROFF_DELAY=0 \
  image/build/build.sh generic-x86_64 virtual --installer
image/verification/qemu/install-test.sh \
  "$(image/build/build.sh --print-dir generic-x86_64 virtual)/installer-serial.img"
```

The interactive and reinstall flows are verified by
`image/verification/qemu/install-interactive-test.sh` and
`image/verification/qemu/reinstall-test.sh`.

## Console selection

`CONSOLE` selects the interactive console for both the installer medium and
the installed OS UKIs (`serial` or `local`). By default both present over the
serial console (`ttyS0` on x86_64, `ttyAMA0` on aarch64; `ttyS2` on `rk35xx`).
For a host with no serial port and an attached HDMI monitor and USB keyboard,
select the local text console instead (the `qdl` `default` profile does this):

```
image/build/build.sh qdl --installer
# or explicitly via the low-level wrapper:
MAKE_INSTALLER=1 CONSOLE=local INSTALLER_TARGET_DISK=interactive \
  image/os/buildroot/build.sh qdl
```

`CONSOLE` accepts `serial` (default) or `local`; any other value fails the
build. `local` runs the installer on `tty1` and adds `console=tty0` to the
installer and OS kernel command lines, keeping the serial console as a
fallback. It requires a board kernel with a framebuffer console (the `qdl`
board provides one).

### Bare metal

Write the installer image to a USB stick or disk, then boot the target from it:

```
sudo dd if="$(image/build/build.sh --print-dir qdl)/installer-local.img" \
  of=/dev/sdX bs=4M conv=fsync status=progress
```

The installer defaults to `/dev/vdb` (a QEMU name); set
`INSTALLER_TARGET_DISK` to the target device (for example `/dev/nvme0n1`) or
to `interactive` to select and confirm on the console. Watch the selected
console for `OBKA_INSTALL_DONE` / `OBKA_INSTALL_EXIT=0`. Interactive media then
wait for Enter before poweroff; non-interactive media wait
`INSTALLER_POWEROFF_DELAY` seconds (default 10).

## Usage

```
build/build-env/run.sh installer/install.sh
```

Overrides:

| Variable        | Default                       | Meaning                       |
|-----------------|-------------------------------|-------------------------------|
| `TARGET_DISK`   | unset (interactive prompt)    | destination block device      |
| `IMAGES_DIR`    | (caller-provided)             | per-slot artifacts to write   |
| `ACTIVE_SLOT`   | `a`                           | slot to boot by default       |
| `PRESERVE_USER` | `1`                           | keep an existing user partition |
| `LAYOUT`        | `<repo>/os/partition-layout.json` | layout metadata           |
| `OBKA_SSH_AUTHORIZED_KEY` | unset               | public key seeded into the `obake` user's home |
| `OBKA_HOSTNAME` | unset (`obake`)             | seed host name (RFC1123); interactive prompt default |

Build-time installer knobs (in addition to `CONSOLE` / `INSTALLER_TARGET_DISK`):

| Variable                   | Default | Meaning                                      |
|----------------------------|---------|----------------------------------------------|
| `INSTALLER_POWEROFF_DELAY` | `10`    | seconds to wait before poweroff when non-interactive; `0` skips the wait (CI) |
