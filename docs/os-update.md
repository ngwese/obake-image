# os-update

User-initiated, signed, A/B operating system updates for an obake host.

For the end-to-end setup flow that installs and updates a host, see
`user-guide.md`.

The update system is provided by the Buildroot image: RAUC (`rauc.service`),
`obake-efi-entries.service`, the health gate, and the `obake-update` client run
on the same slots and bundle format as before. `rauc/system.conf` matches slots
through the `efi` backend. Verified headlessly by
`verification/qemu/update-test.sh` (apply/activate and untrusted-bundle
rejection) and `health-test.sh` (mark-good and revert).

## Bundle format

Updates are RAUC bundles. A bundle carries the inactive root slot's filesystem
plus the matching per-slot unified kernel image, and is signed with the project
release key. The device verifies the signature against `/etc/rauc/ca.cert.pem`
before writing any slot; a bundle that fails verification is rejected and no
slot is changed. Because the bundle is signed, the transport (USB, HTTP, or
HTTPS) is not the trust anchor.

Because each slot's UKI embeds its own `root=PARTLABEL=...`, a bundle is built
for the slot it will be installed into: build it with the target slot's UKI
(`make-bundle.sh <slot> ...`). RAUC installs to whichever slot is inactive, so
the USB/HTTPS bundle must match that inactive slot — if the host reports
`active slot: rootfs.1 (B)`, use the slot-a bundle. A signed
`image/build/build.sh` emits both `obake-<version>-a.raucb` and
`obake-<version>-b.raucb` by default; set `BUNDLE_SLOT=a` or `BUNDLE_SLOT=b`
to emit only one (as the integration harness does).

## Sources

The update client (`obake-update`, configured by `/etc/obake/update.conf`)
accepts bundles from two sources using the same format and signature check:

- **USB media** — preferred when a bundle is present on auto-mounted removable
  media under `/media/<label>` (filesystem label, with a stable fallback when
  unlabeled), so airgapped and AoIP-only hosts can be updated. FAT/FAT32 and
  exFAT sticks are supported.
- **A configured HTTP/HTTPS endpoint** — the `https_url` setting. For TLS, set
  `tls_cacert` to the endpoint's CA certificate (or `tls_insecure=1` for a
  development service).

Updates run only on an explicit request. The `obake` user applies them via
passwordless sudo for `/usr/bin/obake-update` only; the root account is locked.

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
obake-update status                      # running version, active slot, pending
obake-update apply                       # USB under /media preferred, then HTTPS
obake-update apply /path/to/bundle.raucb # install a local signed bundle
obake-update rollback                    # revert to the previous slot
```

`apply` and `rollback` re-exec via `sudo` when run as `obake`. `apply` writes
the inactive root slot and its UKI, then activates the slot for the next boot.
The active slot is never modified. A caller-supplied bundle path is installed
with the same signature verification as USB and HTTPS sources.

`rollback` is the manual counterpart to the health gate: it marks the currently
booted slot bad, activates the other slot (`rauc status mark-active other`),
restores the most recent configuration snapshot, and clears any pending health
state. Reboot to complete the rollback.

## Signing workflow

Generate development signing material (or use production keys held offline):

```sh
image/os/scripts/make-signing-material.sh image/_build/signing
```

Build the per-slot artifacts and a signed bundle. The build emits the bundle
itself when signing material is set:

```sh
RAUC_KEYRING=image/_build/signing/ca.cert.pem \
RAUC_SIGNING_CERT=image/_build/signing/signing.cert.pem \
RAUC_SIGNING_KEY=image/_build/signing/signing.key \
  image/build/build.sh generic-x86_64
```

`image/build/build.sh` resolves those paths for the build container; relative
paths are fine when you invoke it from the repo root. Or bundle an
already-built slot manually with `image/os/scripts/make-bundle.sh` (use
absolute paths, or run it outside the container from a cwd where the relative
paths resolve):

```sh
artifacts="$(image/build/build.sh --print-dir generic-x86_64)"
RAUC_SIGNING_CERT="$PWD/image/_build/signing/signing.cert.pem" \
RAUC_SIGNING_KEY="$PWD/image/_build/signing/signing.key" \
  image/os/scripts/make-bundle.sh b 1.4.0 \
  "$artifacts/root-b.img" "$artifacts/obake-b.efi" image/_out/bundles
```

The CA certificate (`image/_build/signing/ca.cert.pem`) is the keyring baked
into the image via `RAUC_KEYRING` at image build time; the release certificate
signs the bundles. Bumping the pinned kernel or Singularity CE version in
`image/os/buildroot/pins.json`, rebuilding, and bundling ships the new versions
in an update (verified by the harness reporting the installed kernel/version).

## Development update service

Serve bundles from the development/build host to an embedded host on the same
network:

```sh
image/verification/update-server.sh image/_out/bundles 8080
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
