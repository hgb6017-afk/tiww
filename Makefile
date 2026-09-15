ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = DLS

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DLSLowRes
DLSLowRes_FILES = Tweak.xm
DLSLowRes_FRAMEWORKS = Foundation UIKit QuartzCore Metal
DLSLowRes_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
