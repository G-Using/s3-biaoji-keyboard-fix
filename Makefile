ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = S3TextKeyboardFix

S3TextKeyboardFix_FILES = S3TextKeyboardFix.m
S3TextKeyboardFix_CFLAGS = -fobjc-arc -Wno-error -Wno-unguarded-availability -Wno-deprecated-declarations
S3TextKeyboardFix_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
