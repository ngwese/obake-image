# SPDX-FileCopyrightText: Copyright 2026 Greg Wuller
# SPDX-License-Identifier: MIT

################################################################################
#
# obake-ravenna
#
################################################################################

OBAKE_RAVENNA_VERSION = 0.1.0
# BR2_EXTERNAL is image/os/buildroot; three levels up is the repo root.
OBAKE_RAVENNA_SITE = $(BR2_EXTERNAL_OBAKE_PATH)/../../../services/obake-ravenna
OBAKE_RAVENNA_SITE_METHOD = local
OBAKE_RAVENNA_LICENSE = MIT
OBAKE_RAVENNA_REDISTRIBUTE = NO

# Build after PipeWire so PKG_CONFIG can see staging libpipewire. The
# daemon does not retune OBAKE_PIPEWIRE_VERSION or OBAKE_WIREPLUMBER_VERSION.
# libspa-sys/pipewire-sys run bindgen at build time and need host libclang;
# image/build/build-env provides libclang-dev and exports LIBCLANG_PATH.
OBAKE_RAVENNA_DEPENDENCIES = host-rustc obake-pipewire

OBAKE_RAVENNA_CARGO_ENV = \
	PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
	PKG_CONFIG_ALLOW_CROSS=1

# Re-copy from SITE on every extract (build.sh clears extract stamps when
# the source fingerprint changes). --delete drops removed files; skip the
# developer's cargo target/ tree.
define OBAKE_RAVENNA_EXTRACT_CMDS
	rsync -a --delete \
		--exclude target/ \
		--exclude .git/ \
		$(OBAKE_RAVENNA_SITE)/ $(@D)/
endef

# cargo-package defaults to --offline after a vendoring download step. This
# local crate skips vendoring and fetches crates.io over the network instead.
define OBAKE_RAVENNA_BUILD_CMDS
	cd $(@D) && \
	$(TARGET_MAKE_ENV) \
		$(TARGET_CONFIGURE_OPTS) \
		$(PKG_CARGO_ENV) \
		$(OBAKE_RAVENNA_CARGO_ENV) \
		cargo build \
			--release \
			--manifest-path Cargo.toml \
			--locked
endef

define OBAKE_RAVENNA_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 \
		$(@D)/target/$(RUSTC_TARGET_NAME)/release/obake-ravenna \
		$(TARGET_DIR)/usr/bin/obake-ravenna
	$(INSTALL) -D -m 0644 \
		$(OBAKE_RAVENNA_PKGDIR)/obake-ravenna.service \
		$(TARGET_DIR)/usr/lib/systemd/user/obake-ravenna.service
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/systemd/user/default.target.wants
	ln -sf ../obake-ravenna.service \
		$(TARGET_DIR)/usr/lib/systemd/user/default.target.wants/obake-ravenna.service
	$(INSTALL) -D -m 0644 \
		$(OBAKE_RAVENNA_PKGDIR)/20-obake-ravenna-avahi.conf \
		$(TARGET_DIR)/etc/dbus-1/system.d/20-obake-ravenna-avahi.conf
	$(INSTALL) -D -m 0644 \
		$(OBAKE_RAVENNA_PKGDIR)/config.toml \
		$(TARGET_DIR)/usr/share/obake/obake-ravenna/config.toml
	$(INSTALL) -D -m 0644 \
		$(OBAKE_RAVENNA_PKGDIR)/obake-ravenna.conf \
		$(TARGET_DIR)/etc/tmpfiles.d/obake-ravenna.conf
endef

$(eval $(cargo-package))
