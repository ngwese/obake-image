################################################################################
#
# obake-wireplumber
#
################################################################################

OBAKE_WIREPLUMBER_VERSION = 0.5.18
OBAKE_WIREPLUMBER_SITE = $(call github,PipeWire,wireplumber,$(OBAKE_WIREPLUMBER_VERSION))
OBAKE_WIREPLUMBER_SOURCE = wireplumber-$(OBAKE_WIREPLUMBER_VERSION).tar.gz
OBAKE_WIREPLUMBER_LICENSE = MIT
OBAKE_WIREPLUMBER_LICENSE_FILES = LICENSE
OBAKE_WIREPLUMBER_DEPENDENCIES = \
	host-pkgconf obake-pipewire libglib2 lua systemd dbus

# system-lua uses Buildroot Lua (5.4 by default). Introspection pulls
# Python and gobject-introspection and stays off. The user service is
# installed; the system service is not.
OBAKE_WIREPLUMBER_CONF_OPTS = \
	-Ddoc=disabled \
	-Dtests=false \
	-Ddbus-tests=false \
	-Dintrospection=disabled \
	-Dsystem-lua=true \
	-Dsystem-lua-version=auto \
	-Delogind=disabled \
	-Dsystemd=enabled \
	-Dsystemd-system-service=false \
	-Dsystemd-user-service=true

$(eval $(meson-package))
