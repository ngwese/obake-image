# host-config

The writable contract for an obake host: the root is immutable, and every
allowed customization lives in a named, persistent location.

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
| `/home`            | `OBKA_USER` partition            | updates, reinstalls    |
| `/persist`         | `OBKA_PERSIST` partition         | boot, slot switch      |

### `/etc` overlay

The initramfs (`obake-etc-overlay` hook) mounts the persist partition and
overlays the slot's read-only `/etc` with it before `switch_root`, using
`lowerdir=<slot>/etc` and upper/work directories under
`/persist/etc-overlay`. Changes under `/etc` therefore survive reboots and slot
switches and cover machine-specific configuration such as the JACK profiles
under `/etc/jack` and network configuration. A marker file
`/etc/obake/etc-overlay` enables the hook.

### `/var`

`/var` is a tmpfs, so transient runtime state is discarded on reboot. A defined
subset is bind-mounted from the persist partition by
`obake-persist-var.service`, using the list in `/etc/obake/persisted-var`:

```
lib/systemd
lib/NetworkManager
lib/singularity
log/journal
```

### persist partition

`OBKA_PERSIST` is shared across both slots and is not replaced by updates. It
holds the `/etc` overlay, the persisted `/var` subset, the RAUC slot state
(`/persist/rauc`), update snapshots and health state
(`/persist/obake`), and the machine-specific seed written at install time
(machine-id, SSH host keys, hostname, network configuration).

### user partition

`OBKA_USER` is mounted at `/home`. It holds user data and home directories and
is never modified by an operating system update or by a reinstall that
preserves user data.

## Directory contract

`/etc/obake/directory-contract` names the locations a user may customize:
`/etc`, `/var`, `/home`, and `/persist`. Everything else on the root is
read-only.

Users connect over SSH as the `obake` account (home `/home/obake` on the user
partition). Authorized keys are read from `/etc/ssh/authorized_keys.d/<user>` so
access can be provisioned into the image or the persist partition without
writing to the read-only home. Verified behaviour:

- the user can modify files within the contract (e.g. `/home/obake`);
- a write to `/etc` or to the read-only root fails.

OpenSSH's per-source auth penalty (`PerSourcePenalties`) is disabled on these
hosts, which are administered deliberately on trusted networks.

## Verification

- `verification/qemu/persist-test.sh` — writes markers under `/etc`, `/var`, and
  `/home`, reboots, and switches slots, asserting the contract above.
- `verification/qemu/ssh-test.sh` — logs in over SSH and checks the directory
  contract.
