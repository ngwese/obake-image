# Native QEMU verification environment for the obake image harnesses.
#
# The counterpart to ../build-env: the build environment cross-builds an
# artifact directory with no emulator, and this environment boots those
# artifacts under the host's QEMU/KVM. It is native to the host architecture
# and exists for hosts (such as a bare WSL2 install) that have no system
# QEMU/OVMF; hosts that do can run the harnesses directly.
FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        python3 \
        openssl \
        qemu-system-x86 \
        qemu-system-arm \
        qemu-utils \
        ovmf \
        qemu-efi-aarch64 \
        gdisk \
        e2fsprogs \
        mtools \
        dosfstools \
        parted \
        squashfs-tools \
        rauc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work