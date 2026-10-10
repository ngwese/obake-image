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

# Setuid starter + conf ownership applied at rootfs assembly (DESTDIR install
# runs as a non-root user and cannot chmod 4755 / chown root).
define SINGULARITY_PERMISSIONS
	/usr/libexec/singularity/bin/starter-suid f 4755 0 0 - - - - -
	/etc/singularity/singularity.conf f 644 0 0 - - - - -
endef

# Singularity uses its own mconfig/makeit build system, and its CGO code is
# cross-built with the Buildroot Go toolchain (HOST_GO_TARGET_ENV sets
# GOOS/GOARCH and the CGO cross flags).
define SINGULARITY_CONFIGURE_CMDS
	cd $(@D) && \
		CFLAGS="$(SINGULARITY_CFLAGS)" CXXFLAGS="$(SINGULARITY_CFLAGS)" \
		$(TARGET_MAKE_ENV) $(HOST_GO_TARGET_ENV) \
		./mconfig --prefix=/usr --sysconfdir=/etc --localstatedir=/var/lib \
			--without-libsubid \
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

# Pin setuid + kernel SquashFS; drop stale /usr/etc paths from older
# --prefix=/usr builds (sysconfdir defaulted to $(prefix)/etc).
define SINGULARITY_PIN_CONF
	conf="$(TARGET_DIR)/etc/singularity/singularity.conf"; \
	[ -f "$$conf" ] || { echo "missing $$conf" >&2; exit 1; }; \
	$(SED) 's/^allow setuid =.*/allow setuid = yes/' "$$conf"; \
	$(SED) 's/^allow kernel squashfs =.*/allow kernel squashfs = yes/' "$$conf"; \
	grep -q '^allow setuid = yes$$' "$$conf" || \
		echo 'allow setuid = yes' >>"$$conf"; \
	grep -q '^allow kernel squashfs = yes$$' "$$conf" || \
		echo 'allow kernel squashfs = yes' >>"$$conf"; \
	rm -rf "$(TARGET_DIR)/usr/etc/singularity"; \
	mkdir -p "$(TARGET_DIR)/var/lib/singularity/mnt/session"
endef
SINGULARITY_POST_INSTALL_TARGET_HOOKS += SINGULARITY_PIN_CONF

$(eval $(generic-package))
