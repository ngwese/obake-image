################################################################################
#
# obake-jack2
#
################################################################################

OBAKE_JACK2_VERSION = 1.9.22
OBAKE_JACK2_SITE = $(call github,jackaudio,jack2,v$(OBAKE_JACK2_VERSION))
OBAKE_JACK2_SOURCE = jack2-$(OBAKE_JACK2_VERSION).tar.gz
OBAKE_JACK2_LICENSE = GPL-2.0+ (jack server), LGPL-2.1+ (jack library)
OBAKE_JACK2_LICENSE_FILES = COPYING
OBAKE_JACK2_CPE_ID_VENDOR = jackaudio
OBAKE_JACK2_DEPENDENCIES = host-pkgconf alsa-lib dbus expat
OBAKE_JACK2_INSTALL_STAGING = YES

# The waf bundled in jack2 1.9.22 uses the removed `imp` module; the small
# patch in this directory makes it work with Python 3.12+ (the in-tree jack2
# package instead carries the full waf 2.0.26 update).

# Build both the classic server (jackd) and the D-Bus daemon (jackdbus). The
# Python jack_control helper that --dbus also installs is removed below, so no
# Python runtime is required.
OBAKE_JACK2_CONF_OPTS = --alsa --classic --dbus

ifeq ($(BR2_PACKAGE_LIBSAMPLERATE),y)
OBAKE_JACK2_DEPENDENCIES += libsamplerate
OBAKE_JACK2_CONF_OPTS += --samplerate=yes
else
OBAKE_JACK2_CONF_OPTS += --samplerate=no
endif

ifeq ($(BR2_PACKAGE_OPUS),y)
OBAKE_JACK2_DEPENDENCIES += opus
OBAKE_JACK2_CONF_OPTS += --opus=yes
else
OBAKE_JACK2_CONF_OPTS += --opus=no
endif

ifeq ($(BR2_PACKAGE_SYSTEMD),y)
OBAKE_JACK2_DEPENDENCIES += systemd
OBAKE_JACK2_CONF_OPTS += --systemd=yes
else
OBAKE_JACK2_CONF_OPTS += --systemd=no
endif

# jack2 installs the Python jack_control tool unconditionally with --dbus.
# Remove it so the runtime layer needs no Python interpreter or bindings.
define OBAKE_JACK2_REMOVE_JACK_CONTROL
	$(RM) -f $(TARGET_DIR)/usr/bin/jack_control
endef
OBAKE_JACK2_POST_INSTALL_TARGET_HOOKS += OBAKE_JACK2_REMOVE_JACK_CONTROL

$(eval $(waf-package))
