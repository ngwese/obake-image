# Reproducible, host-agnostic build environment for obake OS images.
#
# Pinned to a Debian trixie base digest and a pinned Singularity CE source
# release so the same commands produce equivalent x86_64 images on macOS arm64
# and Windows 11 WSL x86_64. Singularity CE is built from source because trixie
# ships no suitable distribution package.

FROM debian@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS singularity-build

ARG SINGULARITY_VERSION=4.6.0
ARG SINGULARITY_SHA256=920f3e8b3b103b54e9f303c80989ddd6bdac2e1339eab952505cd3fda14b2315
ARG GO_VERSION=1.27.1
ARG GO_SHA256=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        libtool \
        libseccomp-dev \
        libsubid-dev \
        uuid-dev \
        libssl-dev \
        libgpgme-dev \
        libglib2.0-dev \
        libfuse3-dev \
        squashfs-tools \
        squashfs-tools-ng \
        cryptsetup \
        fuse2fs \
        rsync \
        pkg-config \
        wget \
        zlib1g-dev \
        liblzma-dev \
        liblz4-dev \
        libzstd-dev \
        ca-certificates \
        curl \
        git \
    && rm -rf /var/lib/apt/lists/*

# Singularity CE 4.5 requires Go >= 1.25, newer than the trixie toolchain, so a
# pinned upstream Go release is used instead.
ENV PATH="/usr/local/go/bin:${PATH}"
RUN curl -fsSL -o /tmp/go.tar.gz \
        "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

WORKDIR /usr/local/src
RUN curl -fsSL -o singularity-ce.tar.gz \
        "https://github.com/sylabs/singularity/releases/download/v${SINGULARITY_VERSION}/singularity-ce-${SINGULARITY_VERSION}.tar.gz" \
    && echo "${SINGULARITY_SHA256}  singularity-ce.tar.gz" | sha256sum -c - \
    && tar xzf singularity-ce.tar.gz \
    && cd "singularity-ce-${SINGULARITY_VERSION}" \
    && ./mconfig --prefix=/usr/local \
    && make -C builddir -j"$(nproc)" \
    && make -C builddir install DESTDIR=/opt/singularity-root \
    && rm -rf /usr/local/src


FROM debian@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

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
        openssh-client \
        libseccomp2 \
        libssl3t64 \
        libgpgme11t64 \
        libfuse3-4 \
        fuse3 \
        fuse2fs \
        squashfs-tools-ng \
        cryptsetup \
        uidmap \
        runc \
    && rm -rf /var/lib/apt/lists/*

COPY --from=singularity-build /opt/singularity-root /opt/singularity-root

WORKDIR /work
