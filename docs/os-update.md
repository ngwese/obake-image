# os-update

User-initiated, signed, A/B operating system updates for an obake host.

## Bundle format

Updates are RAUC bundles. A bundle carries the inactive root slot's filesystem
plus the matching per-slot unified kernel image, and is signed with the project
release key. The device verifies the signature against `/etc/rauc/ca.cert.pem`
before writing any slot; a bundle that fails verification is rejected and no
slot is changed. Because the bundle is signed, the transport (USB, HTTP, or
HTTPS) is not the trust anchor.

Because each slot's UKI embeds its own `root=PARTLABEL=...`, a bundle is built
for the slot it will be installed into: build it with the target slot's UKI
(`make-bundle.sh <slot> ...`). RAUC installs to whichever slot is inactive, so a
release that must update either slot needs the matching per-slot bundle (or a
bundle carrying both slot UKIs). The `verification/qemu/integration-test.sh`
harness exercises this by installing per-slot bundles in both directions.

## Sources

The update client (`obake-update`, configured by `/etc/obake/update.conf`)
accepts bundles from two sources using the same format and signature check:

- **USB media** — preferred when a bundle is present, so airgapped and
  AoIP-only hosts can be updated.
- **A configured HTTP/HTTPS endpoint** — the `https_url` setting. For TLS, set
  `tls_cacert` to the endpoint's CA certificate (or `tls_insecure=1` for a
  development service).

Updates run only on an explicit request.

## Configuration

`/etc/obake/update.conf` lives under the persistent `/etc` overlay, so edits
survive reboots and slot switches:

```sh
https_url=https://updates.example.net/obake/obake-1.4.0-b.raucb
usb_prefer=1
# tls_cacert=/etc/obake/update-ca.pem
# tls_insecure=0
```

When building or installing an image, set `UPDATE_URL` (build) or
`OBKA_UPDATE_URL` (install) to seed the endpoint.

## Applying an update

```sh
obake-update status     # running version, active slot, pending/activated slot
obake-update apply      # fetch (USB preferred) and install to the inactive slot
obake-update rollback   # manually revert to the previous slot and configuration
```

`apply` writes the inactive root slot and its UKI, then activates the slot for
the next boot. The active slot is never modified.

`rollback` is the manual counterpart to the health gate: it marks the currently
booted slot bad, activates the other slot (`rauc status mark-active other`),
restores the most recent configuration snapshot, and clears any pending health
state. Reboot to complete the rollback.

## Signing workflow

Generate development signing material (or use production keys held offline):

```sh
os/scripts/make-signing-material.sh .build/signing
```

Build the per-slot artifacts and a signed bundle:

```sh
os/build.sh
RAUC_SIGNING_CERT=.build/signing/signing.cert.pem \
RAUC_SIGNING_KEY=.build/signing/signing.key \
  os/scripts/make-bundle.sh b 1.4.0 \
  dist/os/amd64/root-b.img dist/os/amd64/obake-b.efi dist/bundles
```

The CA certificate (`.build/signing/ca.cert.pem`) is the keyring baked into the
image via `RAUC_KEYRING` at image build time; the release certificate signs the
bundles. Bumping the pinned kernel or Singularity CE version in
`os/manifest.json`, rebuilding, and bundling ships the new versions in an
update (verified by the harness reporting the installed kernel/version).

## Development update service

Serve bundles from the development/build host to an embedded host on the same
network:

```sh
verification/update-server.sh dist/bundles 8080
```

HTTP is the default; set `UPDATE_SERVER_TLS=1` for HTTPS with a generated
self-signed certificate (point `tls_cacert` at the generated `tls.crt`). From a
QEMU guest using user networking the build host is at `10.0.2.2`, so
`https_url=http://10.0.2.2:8080/obake-1.4.0-b.raucb` reaches it.

## Health gate and rollback

The shape configuration surface is `/persist/shapes`, owned by
`obake-launcher`, which runs as part of `obake-runtime.target`. Before an
update is applied, `obake-update` snapshots `/persist/shapes` to
`/persist/obake/snapshots/<id>` and marks the update pending in
`/persist/obake/health/pending`.

On boot with an update pending, `obake-health-gate.service` runs before
`multi-user.target` (and before `obake-runtime.target`'s dependents finish) and:

1. calls `obake-launcher health` to validate the running update;
2. on success, marks the slot good with `rauc status mark-good`, clears the
   pending marker, and leaves the configuration in place;
3. on failure, increments the attempt counter and retries on the next boot;
4. once the attempt counter reaches `max_attempts`, marks the slot bad
   (`rauc status mark-bad`), activates the previous slot (`rauc status
   mark-active other`), and restores the prior configuration from the snapshot
   (`obake-launcher restore`). The firmware then boots the previous slot.

Configuration lives in `/etc/obake/health.conf`:

```sh
max_attempts=3      # number of boots to validate before reverting
mock_health=pass    # development mock: pass | fail
```

The criteria are deliberately minimal and observable — ultimately that the
configured shapes and the audio path are running. The `mock_health` value lets
the positive and negative paths be exercised without real audio hardware.

## Status

`obake-update status` reports the running version (from
`/etc/obake/image-version`), the active slot, and any pending/activated slot;
the full `rauc status` output follows.

## RAUC configuration

`../os/rauc/system.conf` defines the `efi` bootloader backend, the `rootfs.0/1`
slots (`bootname=A/B`), and the `boot.0/1` raw slots for the per-slot UKIs on
the ESP. Slot state lives on the persist partition
(`statusfile=/persist/rauc/status`).

## Verification

`verification/qemu/health-test.sh pass|revert` exercises the health gate:
`pass` installs a healthy update and asserts the slot is marked good; `revert`
installs a persistently unhealthy update and asserts it is reverted, the
previous slot boots, and the configuration is restored.

`verification/qemu/update-test.sh` runs the full cycle in QEMU: it builds a
signed bundle, installs it to the inactive slot, reboots with persistent EFI
variables, and asserts the update activated. Modes: `good`, `broken`
(untrusted signature rejected), `https` (fetch from the development service),
and `usb` (USB preferred over the service).
