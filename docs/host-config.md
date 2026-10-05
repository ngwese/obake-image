# host-config

The writable contract for an obake host: the root is immutable, and every
allowed customization lives in a named, persistent location.

## Read-only root

The operating system root is mounted read-only during normal operation. A write
to any path outside the contract fails. This keeps user changes out of the root
so they cannot be lost or conflict with the next update.

## Writable locations

| Path               | Backing                         | Persists across |
|--------------------|---------------------------------|-----------------|
| `/etc`             | overlay upper on persist        | boot, slot switch |
| `/var` (subset)    | persisted subset on persist     | boot, slot switch |
| `/var` (other)     | tmpfs                           | nothing (discarded) |
| `/home`            | user partition                  | updates, preserving reinstalls |
| `/persist`         | persist partition               | boot, slot switch |

### `/etc` overlay

`/etc` is an overlay whose upper and work directories live on the persist
partition. Changes under `/etc` survive reboots and slot switches. This covers
machine-specific configuration such as the JACK profiles under `/etc/jack` and
network configuration.

### `/var`

`/var` is a tmpfs so transient runtime state is discarded on reboot. A defined
subset is bind-mounted from the persist partition for state that must survive.

### persist partition

`OBKA_PERSIST` holds the `/etc` overlay, the persisted `/var` subset, and the
machine-specific seed written at install time (machine-id, SSH host keys,
hostname). It is shared across both slots and is not replaced by updates.

### user partition

`OBKA_USER` holds user data and home directories. It is never modified by an
operating system update or by a reinstall that preserves user data.

## Directory contract

Users connect over SSH and may modify configuration only within the locations
named above. Everything else on the root is read-only. The exact directory list
is finalized as the contract is implemented; the table above is the current
shape.
