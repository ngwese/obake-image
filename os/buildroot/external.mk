# obake Buildroot external tree.
#
# Package makefiles under package/*/*.mk are included here. The tree currently
# carries only board and configuration material; packages are added by later
# changes.

include $(sort $(wildcard $(BR2_EXTERNAL_OBAKE_PATH)/package/*/*.mk))
