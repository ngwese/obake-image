# obake Buildroot external tree.
#
# Package makefiles under package/*/*.mk are included here.

include $(sort $(wildcard $(BR2_EXTERNAL_OBAKE_PATH)/package/*/*.mk))

# RAUC's optional OpenSSL PKCS#11 engine support fails to build against the
# pinned OpenSSL (engine.h include-order bug). obake does not use HSM-backed
# keys, so disable it. This file is included after package/rauc/rauc.mk, so the
# appended option wins.
RAUC_CONF_OPTS += -Dpkcs11_engine=false

# Buildroot disables utmp/wtmp/lastlog in openssh.mk (cross-build heuristic).
# Re-enable so sshd records sessions into /var/log/wtmp for last(1).
OPENSSH_CONF_OPTS := $(filter-out \
	--disable-lastlog --disable-utmp --disable-utmpx \
	--disable-wtmp --disable-wtmpx,$(OPENSSH_CONF_OPTS))

# Inject image-tree git provenance into the kernel release string via the
# LOCALVERSION make variable (appended after CONFIG_LOCALVERSION by
# scripts/setlocalversion). Board configs keep CONFIG_LOCALVERSION (e.g.
# -qdl); build.sh exports OBAKE_KERNEL_LOCALVERSION (-g<shortsha>[-dirty]).
# Using a localversion-* file would place git before the board suffix.
ifeq ($(OBAKE_KERNEL_LOCALVERSION),)
$(error OBAKE_KERNEL_LOCALVERSION is unset; run via image/os/buildroot/build.sh)
endif
LINUX_MAKE_ENV += LOCALVERSION=$(OBAKE_KERNEL_LOCALVERSION)
