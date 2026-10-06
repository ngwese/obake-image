# dev-qemu

Set up a QEMU/KVM virtual host, install obake with the headless installer, and
log in over SSH to inspect the result.

## Prerequisites

- Docker, and the project's build environment:
  `verification/build-env/run.sh` (builds `obake-build-env`).
- Hardware acceleration on the host: `/dev/kvm` (Linux, or Windows 11 WSL2 with
  nested virtualization / "Virtual Machine Platform" enabled). The harnesses
  auto-detect `kvm` → `whpx`/`hax` → `tcg`; see `verification/README.md`.
- An SSH key pair for the `obake` user. You can generate one with
  `ssh-keygen -t ed25519 -f dist/dev/id`.

The installer propagates the public key given by `OBKA_SSH_AUTHORIZED_KEY` into
the **install** (the persist partition), so the installed host is reachable over
SSH and the key survives updates and slot switches.

## Quick path (helper)

The helper builds the OS and installer with your key, installs to a virtual
disk, then boots it with SSH forwarded on port 2222:

```sh
docker run --rm -it --device /dev/kvm -p 2222:2222 \
  -v "$PWD:/work" -w /work obake-build-env verification/qemu/dev-vm.sh
```

Pass `-v` / `--verbose` to trace commands and stream the build and install
output to the terminal (it is also saved under `dist/dev/`); `-h` / `--help`
shows the options.

Then, from another terminal on the host:

```sh
ssh -i dist/dev/id -p 2222 -o StrictHostKeyChecking=no obake@127.0.0.1
```

The helper writes everything under `dist/dev/` (`build.log`, `install.log`,
`id`, `target.img`, `vars*.fd`). `Ctrl-C` stops the VM.

## Manual steps

Start an interactive build-environment container with KVM and the SSH port
published:

```sh
docker run --rm -it --device /dev/kvm -p 2222:2222 \
  -v "$PWD:/work" -w /work obake-build-env bash
```

Everything below runs inside that container.

### 1. Key and build (key baked into the install)

```sh
mkdir -p dist/dev
ssh-keygen -q -t ed25519 -N '' -f dist/dev/id
OBKA_SSH_AUTHORIZED_KEY=/work/dist/dev/id.pub MAKE_INSTALLER=1 os/build.sh
```

This produces `dist/os/amd64/installer.img` plus the per-slot artifacts. The
public key is carried in the installer medium and seeded onto the installed
host's persist partition by `install.sh`.

### 2. Create the target disk

```sh
qemu-img create -f raw dist/dev/target.img 16G
cp /usr/share/OVMF/OVMF_VARS_4M.fd dist/dev/vars-install.fd
```

### 3. Install

Boot the installer with the target attached as the second disk. It installs and
powers off (look for `OBKA_INSTALL_DONE`):

```sh
qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m 2048 \
  -smp cores=4,threads=1,sockets=1 -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=dist/dev/vars-install.fd \
  -drive if=none,id=inst,format=raw,file=dist/os/amd64/installer.img,cache=none,aio=native \
  -device virtio-blk-pci,drive=inst,bootindex=0 \
  -drive if=none,id=tgt,format=raw,file=dist/dev/target.img,cache=none,aio=native \
  -device virtio-blk-pci,drive=tgt,bootindex=1 \
  -nographic
```

### 4. Boot the installed host with SSH forwarded

```sh
cp /usr/share/OVMF/OVMF_VARS_4M.fd dist/dev/vars.fd
qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m 2048 \
  -smp cores=4,threads=1,sockets=1 -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=dist/dev/vars.fd \
  -drive file=dist/dev/target.img,format=raw,if=virtio,cache=none,aio=native \
  -netdev user,id=n0,hostfwd=tcp:0.0.0.0:2222-:22 \
  -device virtio-net-pci,netdev=n0 -nographic
```

Leave this running and, from another terminal on the host:

```sh
ssh -i dist/dev/id -p 2222 -o StrictHostKeyChecking=no obake@127.0.0.1
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
  (`verification/update-server.sh dist/bundles 8080`) and set `https_url` in
  `/etc/obake/update.conf`, then `obake-update apply`; see `os-update.md`.
- The same manual flow is automated by `verification/qemu/install-test.sh`,
  `ssh-test.sh`, and `integration-test.sh`.
