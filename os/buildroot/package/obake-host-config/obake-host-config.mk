################################################################################
#
# obake-host-config
#
################################################################################

OBAKE_HOST_CONFIG_VERSION = 1.0
OBAKE_HOST_CONFIG_SITE = $(BR2_EXTERNAL_OBAKE_PATH)/../../host
OBAKE_HOST_CONFIG_SITE_METHOD = local
OBAKE_HOST_CONFIG_LICENSE = Proprietary
OBAKE_HOST_CONFIG_REDISTRIBUTE = NO

# Provides the host `ukify` (and EFI tooling) used by post-image.sh to build the
# per-slot unified kernel images.
OBAKE_HOST_CONFIG_DEPENDENCIES = host-systemd

define OBAKE_HOST_CONFIG_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/etc/udev/rules.d
	$(INSTALL) -m 0644 $(@D)/udev/*.rules $(TARGET_DIR)/etc/udev/rules.d/
	$(INSTALL) -d $(TARGET_DIR)/usr/share/pipewire/pipewire.conf.d
	$(INSTALL) -m 0644 $(@D)/pipewire/pipewire.conf.d/*.conf \
		$(TARGET_DIR)/usr/share/pipewire/pipewire.conf.d/
	$(INSTALL) -d $(TARGET_DIR)/usr/share/wireplumber/wireplumber.conf.d
	$(INSTALL) -m 0644 $(@D)/wireplumber/wireplumber.conf.d/*.conf \
		$(TARGET_DIR)/usr/share/wireplumber/wireplumber.conf.d/
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/systemd/user/pipewire.service.d
	$(INSTALL) -m 0644 $(@D)/systemd/pipewire.service.d/*.conf \
		$(TARGET_DIR)/usr/lib/systemd/user/pipewire.service.d/
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/systemd/user/wireplumber.service.d
	$(INSTALL) -m 0644 $(@D)/systemd/wireplumber.service.d/*.conf \
		$(TARGET_DIR)/usr/lib/systemd/user/wireplumber.service.d/
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/systemd/user/default.target.wants
	ln -sf ../pipewire.service \
		$(TARGET_DIR)/usr/lib/systemd/user/default.target.wants/pipewire.service
	ln -sf ../wireplumber.service \
		$(TARGET_DIR)/usr/lib/systemd/user/default.target.wants/wireplumber.service
endef

$(eval $(generic-package))
