.PHONY: all clean build_clean

XCODEBUILD_SETTINGS = CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets LaunchScreen.storyboard' ASSETCATALOG_COMPILER_APPICON_NAME='' ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES='' INFOPLIST_KEY_UILaunchStoryboardName=LaunchScreen
DOPAMINE_VERSION ?= 3.0.19

all: Dopamine.ipa

Dopamine.ipa: build/Build/Products/Debug-iphoneos/Dopamine.app
	@echo Ad-Hoc signing Dopamine
	xattr -rc build/Build/Products/Debug-iphoneos/Dopamine.app
	codesign --force --deep --sign - --timestamp=none build/Build/Products/Debug-iphoneos/Dopamine.app
	codesign --force --sign - --entitlements Dopamine/Dopamine.entitlements --timestamp=none build/Build/Products/Debug-iphoneos/Dopamine.app/Dopamine
	rm -rf Payload Dopamine.ipa
	mkdir Payload
	cp -r build/Build/Products/Debug-iphoneos/Dopamine.app Payload/Dopamine.app
	zip -Ar Dopamine.ipa Payload
	rm -rf Payload
	rm -rf Dopamine.tipa
	cp Dopamine.ipa Dopamine.tipa

ifeq ($(NIGHTLY), 1)
build/Build/Products/Debug-iphoneos/Dopamine.app: FORCE
	xcodebuild -project Dopamine.xcodeproj -target Dopamine -sdk iphoneos -configuration Debug CONFIGURATION_BUILD_DIR="$(CURDIR)/build/Build/Products/Debug-iphoneos" $(XCODEBUILD_SETTINGS) MARKETING_VERSION="$(DOPAMINE_VERSION)" GCC_PREPROCESSOR_DEFINITIONS='NIGHTLY=1 COMMIT_HASH=\"$(COMMIT_HASH)\"'
else
build/Build/Products/Debug-iphoneos/Dopamine.app: FORCE
	xcodebuild -project Dopamine.xcodeproj -target Dopamine -sdk iphoneos -configuration Debug CONFIGURATION_BUILD_DIR="$(CURDIR)/build/Build/Products/Debug-iphoneos" $(XCODEBUILD_SETTINGS) MARKETING_VERSION="$(DOPAMINE_VERSION)"
endif
	touch build/Build/Products/Debug-iphoneos/Dopamine.app/Dopamine.roothide
	cp -a Dopamine/Prebuilt/Assets.car build/Build/Products/Debug-iphoneos/Dopamine.app/Assets.car
	mkdir -p build/Build/Products/Debug-iphoneos/Dopamine.app/Base.lproj
	cp -a Dopamine/Prebuilt/Base.lproj/LaunchScreen.storyboardc build/Build/Products/Debug-iphoneos/Dopamine.app/Base.lproj/
	cp -a Dopamine/Resources/*.deb build/Build/Products/Debug-iphoneos/Dopamine.app/
# ifeq ($(PALEHIDE), 1)
	THEOS="$(CURDIR)/../theos" make -C Dopamine/Exploits/palera1n package
	rm -rf build/Build/Products/Debug-iphoneos/Dopamine.app/Frameworks/palera1n.framework
	cp -a Dopamine/Exploits/palera1n/.framework build/Build/Products/Debug-iphoneos/Dopamine.app/Frameworks/palera1n.framework
	for framework in ClearSword DarkSword Titan momentarius; do \
		rm -rf build/Build/Products/Debug-iphoneos/Dopamine.app/Frameworks/$$framework.framework; \
		cp -a Dopamine/Prebuilt/Frameworks/$$framework.framework build/Build/Products/Debug-iphoneos/Dopamine.app/Frameworks/; \
	done
# endif


clean:
	make -C Dopamine/Exploits/palera1n clean
	rm -rf build Payload Dopamine.ipa Dopamine.tipa

build_clean:
	rm -rf Payload build

FORCE: ;
