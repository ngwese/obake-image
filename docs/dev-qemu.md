# dev-qemu

Set up a QEMU/KVM virtual host, install obake with the headless installer, and
log in over SSH to inspect the result.

## Prerequisites

- Docker with the Buildx CLI plugin (Ubuntu: `apt install docker-buildx`), and
  the project's build and verification environments:
  `image/build/build-env/run.sh` (builds the Buildroot artifacts) and
  `image/verification/verify-env/run.sh` (provides QEMU/OVMF on hosts without a
  system QEMU). Prefer `verify-env/run.sh` over a raw `docker run`: it runs as
  your uid/gid and adds the host groups that own `/dev/kvm` and
  `/var/run/docker.sock` when those paths exist. The build wrapper selects the
  build container automatically. Without Buildx those wrappers fail instead of
  falling back to the legacy Docker builder.
- A readable Docker socket (`/var/run/docker.sock`) when a harness must build
  artifacts through nested Docker.
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
disk, then boots it with SSH forwarded on port 2222. Publish the SSH port on
the verify-env container (the wrapper does not publish ports by itself):

```sh
uid="$(id -u)"; gid="$(id -g)"
kvm_g="$(stat -c '%g' /dev/kvm 2>/dev/null || true)"
sock_g="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
docker run --rm -it --user "$uid:$gid" -e HOME=/tmp \
  ${kvm_g:+--group-add "$kvm_g"} ${sock_g:+--group-add "$sock_g"} \
  --device /dev/kvm -p 2222:2222 \
  -v "$PWD:$PWD" -w "$PWD" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/local/bin/docker:ro \
  obake-verify-env image/verification/qemu/dev-vm.sh
```

Or build the image once and use the same identity flags; prefer matching
`verify-env/run.sh` whenever you do not need published ports.

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
published (same identity flags as `verify-env/run.sh`):

```sh
uid="$(id -u)"; gid="$(id -g)"
kvm_g="$(stat -c '%g' /dev/kvm 2>/dev/null || true)"
sock_g="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
docker run --rm -it --user "$uid:$gid" -e HOME=/tmp \
  ${kvm_g:+--group-add "$kvm_g"} ${sock_g:+--group-add "$sock_g"} \
  --device /dev/kvm -p 2222:2222 \
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
OBKA_SSH_AUTHORIZED_KEY="$PWD/image/_dev/id.pub" \
  image/build/build.sh generic-x86_64 virtual --installer
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
cat /etc/os-release /etc/issue
uname -r
cat /etc/obake/kernel /etc/obake/singularity /etc/obake/board
singularity --version
# shapes need USER_NS (non-setuid Singularity); smoke with a local SIF:
#   singularity run /path/to/shape.sif

# writable contract (SSH obake: /home yes, /etc no)
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

System writes to `/etc` land in the overlay on persist; the `obake` SSH user
writes under `/home` and cannot write `/etc`. The rest of the root is
read-only. See `host-config.md`.

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
