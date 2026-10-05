# os-update

User-initiated, signed, A/B operating system updates for an obake host.

## Bundle format

Updates are RAUC bundles. A bundle carries the inactive root slot's filesystem
plus the matching per-slot unified kernel image, and is signed with the project
signing key. The device verifies the signature against `/etc/rauc/ca.cert.pem`
before writing any slot; an unsigned or tampered bundle is rejected with no
changes.

## Sources

The update client accepts bundles from two sources using the same format and the
same signature check:

- **USB media** — preferred when a bundle is present, so airgapped and
  AoIP-only hosts can be updated.
- **Signed HTTPS endpoint** — the configured remote source.

Updates run only on explicit user request.

## Applying

Applying writes the inactive root slot and its UKI, then activates the slot on
the next boot. The active slot is never modified. Kernel and userspace change
together because the UKI is version-locked to the slot.

## Health gate and rollback

On boot with an update pending, the health-gate service restores the prior user
configuration from a snapshot on the persist partition and validates the running
update over a bounded number of boots. On success it marks the slot good. If the
slot is not marked good within that bound, systemd-boot's boot counting reverts
to the previous slot.

## Status

A status query reports the running version, the active slot, and the state of
any pending or failed update.

## RAUC configuration

`../os/rauc/system.conf` defines the slots (`OBKA_ROOT_A`, `OBKA_ROOT_B`) and the
`efi` bootloader backend.
