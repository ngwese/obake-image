# SPDX-FileCopyrightText: Copyright 2026 Greg Wuller
# SPDX-License-Identifier: MIT

################################################################################
#
# obake-session
#
################################################################################

OBAKE_SESSION_VERSION = 0.1.0
# BR2_EXTERNAL is image/os/buildroot; three levels up is the repo root.
OBAKE_SESSION_SITE = $(BR2_EXTERNAL_OBAKE_PATH)/../../../services
OBAKE_SESSION_SITE_METHOD = local
OBAKE_SESSION_LICENSE = MIT
OBAKE_SESSION_REDISTRIBUTE = NO

OBAKE_SESSION_DEPENDENCIES = host-rustc obake-pipewire

OBAKE_SESSION_CARGO_ENV = \
	PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
	PKG_CONFIG_ALLOW_CROSS=1

define OBAKE_SESSION_EXTRACT_CMDS
	rsync -a --delete \
		--exclude target/ \
		--exclude '*/target/' \
		--exclude .git/ \
		$(OBAKE_SESSION_SITE)/ $(@D)/
endef

# Build the service (may link PipeWire in later revisions) and the
# portable CLI as separate cargo invocations.
define OBAKE_SESSION_BUILD_CMDS
	cd $(@D) && \
	$(TARGET_MAKE_ENV) \
		$(TARGET_CONFIGURE_OPTS) \
		$(PKG_CARGO_ENV) \
		$(OBAKE_SESSION_CARGO_ENV) \
		cargo build \
			--release \
			--manifest-path Cargo.toml \
			--locked \
			-p obake-session
	cd $(@D) && \
	$(TARGET_MAKE_ENV) \
		$(TARGET_CONFIGURE_OPTS) \
		$(PKG_CARGO_ENV) \
		cargo build \
			--release \
			--manifest-path Cargo.toml \
			--locked \
			-p obake
endef

define OBAKE_SESSION_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 \
		$(@D)/target/$(RUSTC_TARGET_NAME)/release/obake-session \
		$(TARGET_DIR)/usr/bin/obake-session
	$(INSTALL) -D -m 0755 \
		$(@D)/target/$(RUSTC_TARGET_NAME)/release/obake \
		$(TARGET_DIR)/usr/bin/obake
	$(INSTALL) -D -m 0644 \
		$(OBAKE_SESSION_PKGDIR)/obake-session.service \
		$(TARGET_DIR)/usr/lib/systemd/user/obake-session.service
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/systemd/user/default.target.wants
	ln -sf ../obake-session.service \
		$(TARGET_DIR)/usr/lib/systemd/user/default.target.wants/obake-session.service
	$(INSTALL) -D -m 0644 \
		$(OBAKE_SESSION_PKGDIR)/host.yaml \
		$(TARGET_DIR)/usr/share/obake/obake-session/host.yaml
	$(INSTALL) -D -m 0644 \
		$(OBAKE_SESSION_PKGDIR)/obake-session.conf \
		$(TARGET_DIR)/etc/tmpfiles.d/obake-session.conf
endef

$(eval $(cargo-package))
