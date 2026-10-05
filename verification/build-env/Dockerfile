FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        mmdebstrap \
        debootstrap \
        systemd-ukify \
        systemd-boot-efi \
        initramfs-tools \
        rauc \
        openssl \
        gdisk \
        parted \
        dosfstools \
        e2fsprogs \
        mtools \
        squashfs-tools \
        zstd \
        cpio \
        kmod \
        rsync \
        fakeroot \
        qemu-system-x86 \
        qemu-utils \
        ovmf \
        python3 \
        git \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
