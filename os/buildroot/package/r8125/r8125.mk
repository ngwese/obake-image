################################################################################
#
# r8125
#
################################################################################

R8125_VERSION = 9.018.00
R8125_SOURCE = r8125-$(R8125_VERSION).tar.bz2
R8125_SITE = file://$(BR2_EXTERNAL_OBAKE_PATH)/package/r8125
R8125_SITE_METHOD = file
R8125_LICENSE = GPL-2.0-only
R8125_LICENSE_FILES = src/Makefile

# Command-line assignments override the vendor Makefile defaults.
# PTP on; EEE, ASPM, SoC-LAN, DASH, multi-queue, and RSS off.
# PHY firmware stays inside the module.
R8125_MODULE_SUBDIRS = src
R8125_MODULE_MAKE_OPTS = \
	ENABLE_PTP_SUPPORT=y \
	ENABLE_EEE=n \
	CONFIG_ASPM=n \
	CONFIG_SOC_LAN=n \
	ENABLE_DASH_SUPPORT=n \
	ENABLE_MULTIPLE_TX_QUEUE=n \
	ENABLE_RSS_SUPPORT=n \
	ENABLE_USE_FIRMWARE_FILE=n

$(eval $(kernel-module))
$(eval $(generic-package))
