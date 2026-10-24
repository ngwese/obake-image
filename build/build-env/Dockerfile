# Native, cross-building environment for the obake Buildroot image.
#
# Runs on the host architecture (arm64 on Apple silicon, x86_64 on Intel/WSL)
# and cross-compiles the target with Buildroot. It does NOT include QEMU or
# OVMF: the build emits artifacts and verification consumes them separately
# (see ../README.md), so the build host never runs emulated guests.
FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        wget \
        ca-certificates \
        python3 \
        cpio \
        unzip \
        rsync \
        bc \
        file \
        libncurses-dev \
        patch \
        perl \
        bzip2 \
        gawk \
        sed \
        tar \
        gzip \
        findutils \
        diffutils \
        which \
        fakeroot \
        gdisk \
        dosfstools \
        e2fsprogs \
        mtools \
        parted \
        openssl \
        rauc \
        squashfs-tools \
        libclang-dev \
    && rm -rf /var/lib/apt/lists/*

# Buildroot builds some host tools as root.
ENV FORCE_UNSAFE_CONFIGURE=1

# libclang-dev: bindgen (pipewire-sys / obake-ravenna). run.sh sets
# LIBCLANG_PATH to the matching /usr/lib/llvm-*/lib directory.

WORKDIR /work
