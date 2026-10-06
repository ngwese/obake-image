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

define OBAKE_HOST_CONFIG_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/etc/udev/rules.d
	$(INSTALL) -m 0644 $(@D)/udev/*.rules $(TARGET_DIR)/etc/udev/rules.d/
	$(INSTALL) -d $(TARGET_DIR)/etc/jack
	$(INSTALL) -m 0644 $(@D)/jack/*.conf $(TARGET_DIR)/etc/jack/
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/systemd/user
	$(INSTALL) -m 0644 $(@D)/jack/jack@.service \
		$(TARGET_DIR)/usr/lib/systemd/user/jack@.service
endef

$(eval $(generic-package))
