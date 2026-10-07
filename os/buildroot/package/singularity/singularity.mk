################################################################################
#
# singularity
#
################################################################################

SINGULARITY_VERSION = 4.5.1
SINGULARITY_SITE = https://github.com/sylabs/singularity/releases/download/v$(SINGULARITY_VERSION)
SINGULARITY_SOURCE = singularity-ce-$(SINGULARITY_VERSION).tar.gz
SINGULARITY_LICENSE = BSD-3-Clause
SINGULARITY_LICENSE_FILES = LICENSE.md
SINGULARITY_DEPENDENCIES = \
	host-go host-pkgconf \
	libseccomp libgpgme cryptsetup libfuse3 \
	openssl zlib lz4 xz zstd lzo \
	util-linux e2fsprogs squashfs

# Singularity's makeit and Go's cgo both add -D_FORTIFY_SOURCE, clashing with
# Buildroot's CFLAGS under -Werror. Drop it here; Buildroot's hardened flags
# still apply to the rest of the system.
SINGULARITY_CFLAGS = $(filter-out -D_FORTIFY_SOURCE=%,$(TARGET_CFLAGS))

# Singularity uses its own mconfig/makeit build system, and its CGO code is
# cross-built with the Buildroot Go toolchain (HOST_GO_TARGET_ENV sets
# GOOS/GOARCH and the CGO cross flags).
define SINGULARITY_CONFIGURE_CMDS
	cd $(@D) && \
		CFLAGS="$(SINGULARITY_CFLAGS)" CXXFLAGS="$(SINGULARITY_CFLAGS)" \
		$(TARGET_MAKE_ENV) $(HOST_GO_TARGET_ENV) \
		./mconfig --prefix=/usr --without-suid --without-libsubid \
			-C "$(TARGET_CC)" -X "$(TARGET_CXX)"
endef

define SINGULARITY_BUILD_CMDS
	cd $(@D) && $(TARGET_MAKE_ENV) $(HOST_GO_TARGET_ENV) \
		CGO_CFLAGS="$(SINGULARITY_CFLAGS)" \
		CGO_CXXFLAGS="$(SINGULARITY_CFLAGS)" \
		CFLAGS="$(SINGULARITY_CFLAGS)" \
		$(MAKE) -C builddir
endef

define SINGULARITY_INSTALL_TARGET_CMDS
	cd $(@D) && $(TARGET_MAKE_ENV) $(HOST_GO_TARGET_ENV) \
		$(MAKE) -C builddir install DESTDIR=$(TARGET_DIR)
endef

$(eval $(generic-package))
