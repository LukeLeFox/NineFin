TARGET = iphone:clang:9.2:9.0
ARCHS = armv7
PACKAGE_FORMAT = ipa
TARGET_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/NineFin.entitlements

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = NineFin
NineFin_FILES = main.m NFDownloadManager.m NFDownloadsController.m
NineFin_FRAMEWORKS = UIKit Foundation AVKit AVFoundation Security SystemConfiguration
NineFin_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk
