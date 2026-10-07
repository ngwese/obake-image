# obake Buildroot external tree.
#
# Package makefiles under package/*/*.mk are included here.

include $(sort $(wildcard $(BR2_EXTERNAL_OBAKE_PATH)/package/*/*.mk))
