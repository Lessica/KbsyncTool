TARGET := iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = itunesstored
export THEOS_DEVICE_IP = 127.0.0.1
export THEOS_DEVICE_PORT = 58422

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KbsyncTweak

KbsyncTweak_FILES = Tweak.xm
KbsyncTweak_CFLAGS = -fobjc-arc
KbsyncTweak_LIBRARIES = rocketbootstrap
KbsyncTweak_PRIVATE_FRAMEWORKS = Accounts AppSupport StoreServices
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS = kbsynctool
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 AppStore; killall -9 itunesstored; killall -9 appstored 2>/dev/null &"
