################################################################################
#
# obake-pipewire
#
################################################################################

OBAKE_PIPEWIRE_VERSION = 1.6.10
OBAKE_PIPEWIRE_SITE = $(call github,PipeWire,pipewire,$(OBAKE_PIPEWIRE_VERSION))
OBAKE_PIPEWIRE_SOURCE = pipewire-$(OBAKE_PIPEWIRE_VERSION).tar.gz
OBAKE_PIPEWIRE_LICENSE = MIT, LGPL-2.1+ (libspa-alsa), GPL-2.0 (libjackserver)
OBAKE_PIPEWIRE_LICENSE_FILES = COPYING LICENSE
OBAKE_PIPEWIRE_INSTALL_STAGING = YES
OBAKE_PIPEWIRE_DEPENDENCIES = \
	host-pkgconf alsa-lib dbus libsndfile ncurses readline systemd \
	$(TARGET_NLS_DEPENDENCIES)
OBAKE_PIPEWIRE_LDFLAGS = $(TARGET_NLS_LIBS)

# 1.6 defaults that must be overridden: session-managers fetches WirePlumber
# as a subproject, flatpak and pipewire-v4l2 are enabled, legacy-rtkit and
# rlimits-install are true, and jack=auto becomes a jackd client if jack2
# is present. In-tree Buildroot pipewire stays unselected.
OBAKE_PIPEWIRE_CONF_OPTS = \
	-Ddocs=disabled \
	-Dman=disabled \
	-Dexamples=disabled \
	-Dtests=disabled \
	-Dinstalled_tests=disabled \
	-Dspa-plugins=enabled \
	-Daudiomixer=enabled \
	-Daudioconvert=enabled \
	-Dcontrol=enabled \
	-Daudiotestsrc=enabled \
	-Dsupport=enabled \
	-Devl=disabled \
	-Dtest=disabled \
	-Dvideoconvert=enabled \
	-Dvideotestsrc=enabled \
	-Dvolume=disabled \
	-Dvulkan=disabled \
	-Dsession-managers=[] \
	-Dlegacy-rtkit=false \
	-Drlimits-install=false \
	-Dpam-defaults-install=false \
	-Davb=disabled \
	-Droc=disabled \
	-Dlibcanberra=disabled \
	-Dlibmysofa=disabled \
	-Dlibffado=disabled \
	-Dflatpak=disabled \
	-Dsnap=disabled \
	-Ddbus=enabled \
	-Dudev=enabled \
	-Dalsa=enabled \
	-Dpipewire-alsa=enabled \
	-Dpipewire-jack=enabled \
	-Djack=disabled \
	-Djack-devel=false \
	-Dlibpulse=disabled \
	-Dlibsystemd=enabled \
	-Dlogind=enabled \
	-Dlogind-provider=libsystemd \
	-Dsystemd-system-service=disabled \
	-Dsystemd-user-service=enabled \
	-Dgstreamer=disabled \
	-Dgstreamer-device-provider=disabled \
	-Dbluez5=disabled \
	-Dffmpeg=disabled \
	-Dpw-cat-ffmpeg=disabled \
	-Dpipewire-v4l2=disabled \
	-Dv4l2=disabled \
	-Dlibcamera=disabled \
	-Dlv2=disabled \
	-Dx11=disabled \
	-Dx11-xfixes=disabled \
	-Dgsettings=disabled \
	-Dgsettings-pulse-schema=disabled \
	-Dlibusb=disabled \
	-Dpw-cat=enabled \
	-Dsndfile=enabled \
	-Dopus=disabled \
	-Dreadline=enabled \
	-Dsdl2=disabled \
	-Dcompress-offload=disabled \
	-Decho-cancel-webrtc=disabled \
	-Draop=disabled \
	-Davahi=disabled \
	-Dselinux=disabled \
	-Debur128=disabled \
	-Dfftw=disabled \
	-Donnxruntime=disabled

# The user service is installed unconditionally with pipewire-pulse. The
# image has no Pulse client library and must not ship the pulse unit.
define OBAKE_PIPEWIRE_REMOVE_PULSE
	$(RM) -f $(TARGET_DIR)/usr/bin/pipewire-pulse
	$(RM) -f $(TARGET_DIR)/usr/lib/systemd/user/pipewire-pulse.service
	$(RM) -f $(TARGET_DIR)/usr/lib/systemd/user/pipewire-pulse.socket
	$(RM) -f $(TARGET_DIR)/usr/lib/systemd/system/pipewire-pulse.service
	$(RM) -f $(TARGET_DIR)/usr/lib/systemd/system/pipewire-pulse.socket
endef
OBAKE_PIPEWIRE_POST_INSTALL_TARGET_HOOKS += OBAKE_PIPEWIRE_REMOVE_PULSE

$(eval $(meson-package))
