# obake Buildroot external tree.
#
# Package makefiles under package/*/*.mk are included here.

include $(sort $(wildcard $(BR2_EXTERNAL_OBAKE_PATH)/package/*/*.mk))

# RAUC's optional OpenSSL PKCS#11 engine support fails to build against the
# pinned OpenSSL (engine.h include-order bug). obake does not use HSM-backed
# keys, so disable it. This file is included after package/rauc/rauc.mk, so the
# appended option wins.
RAUC_CONF_OPTS += -Dpkcs11_engine=false
