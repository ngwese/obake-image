# dev-qemu

Set up a QEMU/KVM virtual host, install obake with the headless installer, and
log in over SSH to inspect the result.

## Prerequisites

- Docker, and the project's build and verification environments:
  `image/build/build-env/run.sh` (builds the Buildroot artifacts) and
  `image/verification/verify-env/run.sh` (provides QEMU/OVMF on hosts without a
  system QEMU). The build wrapper selects the build container automatically.
- Hardware acceleration on the host: `/dev/kvm` (Linux, or Windows 11 WSL2 with
  nested virtualization / "Virtual Machine Platform" enabled). The harnesses
  auto-detect `kvm` → `hvf` → `whpx`/`hax` → `tcg`; see
  `image/verification/README.md`.
- An SSH key pair for the `obake` user. You can generate one with
  `ssh-keygen -t ed25519 -f image/_dev/id`.

The installer propagates the public key given by `OBKA_SSH_AUTHORIZED_KEY` into
the **install** (the persist partition), so the installed host is reachable over
SSH and the key survives updates and slot switches.

## Quick path (helper)

The helper builds the OS and installer with your key, installs to a virtual
disk, then boots it with SSH forwarded on port 2222:

```sh
docker run --rm -it --device /dev/kvm -p 2222:2222 \
  -v "$PWD:$PWD" -w "$PWD" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/local/bin/docker:ro \
  obake-verify-env image/verification/qemu/dev-vm.sh
```

Pass `-v` / `--verbose` to trace commands and stream the build and install
output to the terminal (it is also saved under `image/_dev/`); `-h` / `--help`
shows the options.

Then, from another terminal on the host:

```sh
ssh -i image/_dev/id -p 2222 -o StrictHostKeyChecking=no obake@127.0.0.1
```

The helper writes everything under `image/_dev/` (`build.log`, `install.log`,
`id`, `target.img`, `vars*.fd`). `Ctrl-C` stops the VM.

## Manual steps

Start an interactive verification container with KVM and the SSH port
published:

```sh
docker run --rm -it --device /dev/kvm -p 2222:2222 \
  -v "$PWD:$PWD" -w "$PWD" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/local/bin/docker:ro \
  obake-verify-env bash
```

Everything below runs inside that container. The build wrapper uses the
Buildroot build container through the mounted Docker socket.

### 1. Key and build (key baked into the install)

```sh
mkdir -p image/_dev
ssh-keygen -q -t ed25519 -N '' -f image/_dev/id
OBKA_SSH_AUTHORIZED_KEY="$PWD/image/_dev/id.pub" MAKE_INSTALLER=1 \
  image/build/build.sh generic-x86_64 virtual
```

This produces `installer-serial.img` under the board's `virtual` artifact
directory (printed as `artifact: ...`) plus the per-slot artifacts. The public
key is carried in the installer medium and seeded onto the installed host's
persist partition by `install.sh`.

### 2. Create the target disk

```sh
qemu-img create -f raw image/_dev/target.img 16G
cp /usr/share/OVMF/OVMF_VARS_4M.fd image/_dev/vars-install.fd
```

### 3. Install

Boot the installer with the target attached as the second disk. It installs and
powers off (look for `OBKA_INSTALL_DONE`):

```sh
installer="$(image/build/build.sh --print-dir generic-x86_64 virtual)/installer-serial.img"
qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m 2048 \
  -smp cores=4,threads=1,sockets=1 -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=image/_dev/vars-install.fd \
  -drive if=none,id=inst,format=raw,file=$installer,cache=none,aio=native \
  -device virtio-blk-pci,drive=inst,bootindex=0 \
  -drive if=none,id=tgt,format=raw,file=image/_dev/target.img,cache=none,aio=native \
  -device virtio-blk-pci,drive=tgt,bootindex=1 \
  -nographic
```

### 4. Boot the installed host with SSH forwarded

```sh
cp /usr/share/OVMF/OVMF_VARS_4M.fd image/_dev/vars.fd
qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m 2048 \
  -smp cores=4,threads=1,sockets=1 -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=image/_dev/vars.fd \
  -drive file=image/_dev/target.img,format=raw,if=virtio,cache=none,aio=native \
  -netdev user,id=n0,hostfwd=tcp:0.0.0.0:2222-:22 \
  -device virtio-net-pci,netdev=n0 -nographic
```

Leave this running and, from another terminal on the host:

```sh
ssh -i image/_dev/id -p 2222 -o StrictHostKeyChecking=no obake@127.0.0.1
```

## Inspecting the result

```sh
# running version and slot state
cat /etc/obake/image-version
obake-update status
rauc status

# system identity
cat /etc/obake/kernel /etc/obake/singularity /etc/obake/board
singularity --version

# writable contract
findmnt / /etc /var /home /persist
cat /etc/obake/directory-contract

# network / services
resolvectl status
getent hosts deb.debian.org
systemctl is-active avahi-daemon
git --version

# privileged systemctl as obake (polkit), no password
systemctl restart obake-launcher.service

# user data and shape configuration
ls -la /home/obake /persist/shapes
```

Writes to `/etc` land in the overlay on persist, `/home` is the separate user
partition, and the rest of the root is read-only. See `host-config.md`.

## Notes

- Reinstall over an existing disk preserves the user partition:
  re-run the installer against `target.img` (the installer defaults to
  `PRESERVE_USER=1`).
- To update the running host, serve a bundle from the build host
  (`image/verification/update-server.sh image/_out/bundles 8080`) and set
  `https_url` in `/etc/obake/update.conf`, then `obake-update apply`; see
  `os-update.md`.
- The same manual flow is automated by `verification/qemu/install-test.sh`,
  `ssh-test.sh`, and `integration-test.sh`.
