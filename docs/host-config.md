# host-config

The writable contract for an obake host: the root is immutable, and every
allowed customization lives in a named, persistent location.

For the end-to-end setup flow that installs and uses this contract, see
`user-guide.md`.

The contract is provided by the Buildroot image: the initramfs mounts the root
slot by label and overlays `/etc` from the persist partition before handing off
to systemd; `fstab` mounts `/var` as tmpfs with its persisted subset bound from
persist, the user partition at `/home`, and the ESP at `/boot/efi` (VFAT with
`umask=0022` so `obake` can read and list the mount without sudo; writes stay
root-owned). Verified headlessly by `verification/qemu/persist-test.sh` and
`verify-test.sh`.

## Read-only root

The operating system root is mounted read-only (`ro` on the kernel command
line). A write to any path outside the contract fails because the filesystem is
mounted read-only.

## Writable locations

| Path               | Backing                          | Persists across        |
|--------------------|----------------------------------|------------------------|
| `/etc`             | overlay upper on `/persist`      | boot, slot switch      |
| `/var` (subset)    | bind mount from `/persist/var`   | boot, slot switch      |
| `/var` (other)     | tmpfs                            | nothing (discarded)    |
| `/media`           | tmpfs (mountpoint root)          | nothing (discarded)    |
| `/tmp`             | tmpfs (`nosuid`; device nodes allowed) | nothing (discarded) |
| `/home`            | `OBKA_USER` partition            | updates, reinstalls    |
| `/persist`         | `OBKA_PERSIST` partition         | boot, slot switch      |

### `/etc` overlay

The initramfs (`obake-etc-overlay` hook) mounts the persist partition and
overlays the slot's read-only `/etc` with it before `switch_root`, using
`lowerdir=<slot>/etc` and upper/work directories under
`/persist/etc-overlay`. Changes under `/etc` therefore survive reboots and slot
switches and cover machine-specific configuration such as network
configuration. PipeWire factory config is on the read-only image; `obake`
overrides it under `/home/obake/.config/pipewire/` and
`/home/obake/.config/wireplumber/`, which live on the user partition. A
marker file
`/etc/obake/etc-overlay` enables the hook.

### `/var`

`/var` is a tmpfs, so transient runtime state is discarded on reboot. A defined
subset is bind-mounted from the persist partition by
`obake-persist-var.service`, using the list in `/etc/obake/persisted-var`:

```
lib/systemd
lib/NetworkManager
lib/singularity
log
```

`log` covers the system journal (`log/journal`) and login accounting
(`/var/log/wtmp`, `btmp`, `lastlog`) so `last` history survives reboot and
slot switch.

### `/tmp`

`/tmp` is a separate volatile tmpfs, mounted by systemd's `tmp.mount` with an
image drop-in that keeps `nosuid` and allows device nodes. Contents are
discarded on boot and are not part of the persisted `/var` subset. Singularity
uses this directory as its default build sandbox.

### persist partition

`OBKA_PERSIST` is shared across both slots and is not replaced by updates. It
holds the `/etc` overlay, the persisted `/var` subset, the RAUC slot state
(`/persist/rauc`), update snapshots and health state
(`/persist/obake`), and the machine-specific seed written at install time
(machine-id, SSH host keys, hostname, network configuration). The identity seed
is written into the `/etc` overlay upper (`/persist/etc-overlay/upper`), so the
installed host's `/etc` reflects it.

### user partition

`OBKA_USER` is mounted at `/home`. It holds user data and home directories and
is never modified by an operating system update or by a reinstall that
preserves user data.

## Network and tooling

- `systemd-networkd` runs DHCP on wired interfaces
  (`/etc/systemd/network/20-obake-wired.network`). Wired links use
  `RequiredForOnline=no`, so an uncabled boot does not fail
  `systemd-networkd-wait-online` or leave the system degraded. DHCP still
  applies when a cable is present. The installer seeds the same file onto the
  persist `/etc` overlay; OTA does not rewrite an already-seeded copy, so an
  older host may need a one-line `[Link]` / `RequiredForOnline=no` edit (or a
  reinstall that recreates the seed) to pick up the optional-cabling policy.
- `systemd-resolved` provides DNS; `/etc/resolv.conf` is the standard symlink
  to `/run/systemd/resolve/stub-resolv.conf`, so names from DHCP resolve.
- `avahi-daemon` (with `libnss-mdns`) provides mDNS/`.local` name resolution.
- `git` is installed for inspecting and fetching configuration repositories.

## Directory contract

`/etc/obake/directory-contract` names the mounts that are system-writable for
host configuration and user data: `/etc`, `/var`, `/media`, `/home`, and
`/persist`. Everything else on the root is read-only. System services (and
root) write the `/etc` overlay and other contract mounts; the `obake` SSH
login is narrower.

Users connect over SSH as the `obake` account (home `/home/obake` on the user
partition). Authorized keys are read from `~/.ssh/authorized_keys`, owned by
`obake`, so the user manages their own keys without sudo and they survive
updates and slot switches. `/etc/ssh/authorized_keys.d/<user>` remains but is
empty by default, available only for root-provisioned keys. Verified
behaviour:

- the user can modify files under `/home/obake`;
- a write to `/etc` or to the read-only root fails.

`obake` can also rename the host over SSH without sudo
(`hostnamectl set-hostname <name>`); the name is written into the persist
`/etc` overlay and survives boots, slot switches, and updates. The host name is
not carried in `/etc/hosts`; the local name resolves through the system
resolver (`systemd-resolved` with the `myhostname` NSS module), so a rename
needs no `/etc/hosts` edit.

`obake-linger.service` starts the `obake` user manager at boot so the
PipeWire and WirePlumber user services come up without a login. The daemon
socket is `/run/user/<uid>/pipewire-0`. Linux-PAM is enabled: SSH and login
sessions run `pam_systemd` (so `XDG_RUNTIME_DIR` and the session bus are set
for interactive logins) and `pam_limits` (so `@audio` rtprio 95 and unlimited
memlock from `/etc/security/limits.d` apply). `systemctl --user` works in an
interactive SSH session without manually exporting those variables. Non-login
remote commands (`ssh host cmd`) do not open a PAM login session; use an
interactive login or `bash -lc '...'` when you need that environment.

OpenSSH's per-source auth penalty (`PerSourcePenalties`) is disabled on these
hosts, which are administered deliberately on trusted networks.

### Privileged access

Narrowly scoped grants let `obake` administer the host over SSH; none widens
the read-only root or the directory contract:

- A polkit rule (`/etc/polkit-1/rules.d/49-obake.rules`) grants full systemd
  unit management and power control over SSH without interactive
  authentication: `systemctl start|stop|restart|enable`, `systemctl poweroff`,
  and `systemctl reboot` work as `obake` with no password.
- The same polkit rule grants the hostname actions, so
  `hostnamectl set-hostname <name>` renames the host over SSH without a
  password.
- `kernel.dmesg_restrict = 0` (`/etc/sysctl.d/90-obake.conf`) allows reading the
  kernel ring buffer with `dmesg`.
- Membership in the `systemd-journal` group (declared in
  `/usr/lib/sysusers.d/obake.conf`) gives `journalctl` read access to the full
  system journal, not just `obake`'s own messages.
- Passwordless sudo for all commands (`/etc/sudoers.d/obake-update`), including
  interactive root shells (`sudo -s`, `sudo -i`) and `obake-update apply` /
  `rollback`. Escalate with sudo for debugging; do not unlock the root account.

The root account is locked (no usable password): empty-password `su -` as
`obake` fails. Operators use SSH as `obake`, not a root login.

Without sudo, the root filesystem stays read-only and root-owned, so unprivileged
writes stay inside the directory contract. Prefer `/home` and `/persist` for
lasting changes; remounting the slot root read-write is possible via sudo but
breaks the update contract. Only the systemd/power grant is polkit; the
kernel-log grant is a sysctl and the journal grant is filesystem group access.

### Removable media

`/media` is a volatile tmpfs mount root (same idea as `/var`): mountpoint
directories can be created despite the read-only OS image. USB and other
removable filesystem partitions are auto-mounted for `obake` under
`/media/<label>`, where `<label>` is the filesystem label when present
(sanitized), or a stable fallback from UUID / PARTUUID / device name when
unlabeled. Mounts land in the host mount namespace so they are visible to
`obake` and to Singularity binds of `/media`. MS-DOS FAT, FAT32 (VFAT), and
exFAT are supported in the kernel. `obake-update` prefers bundles already
mounted under `/media`.

## Verification

- `verification/qemu/persist-test.sh` — writes markers under `/etc`, `/var`,
  `/tmp`, and `/home`, reboots, and switches slots, asserting the contract
  above.
- `verification/qemu/ssh-test.sh` — logs in over SSH and checks the directory
  contract, polkit systemd/power control, and `dmesg`/journal read access.
