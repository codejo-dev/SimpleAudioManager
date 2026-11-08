# SimpleAudioManager build shortcuts.
#   make driver     build the HAL driver (build/Debug/SimpleAudioManager.driver)
#   make app        build the app (includes the driver)
#   make test       run all unit tests
#   make install    install the driver into /Library/Audio/Plug-Ins/HAL (sudo)
#   make run        build and launch the app
#   make logs       stream the driver's log
#   make release VERSION=1.2.3   build dist/SimpleAudioManager-1.2.3.zip

CONFIG ?= Debug
BUILD := $(CURDIR)/build
ARCH := $(shell uname -m)
APP = $(BUILD)/$(CONFIG)/Simple Audio Manager.app
XCB := xcodebuild -project SimpleAudioManager.xcodeproj -configuration $(CONFIG) SYMROOT=$(BUILD)

.PHONY: project driver app test install uninstall run logs release clean

SimpleAudioManager.xcodeproj: project.yml
	xcodegen generate -q

project: SimpleAudioManager.xcodeproj

driver: project
	$(XCB) -target SAMDriver build -quiet

app: project
	$(XCB) -scheme SimpleAudioManager -destination 'platform=macOS,arch=$(ARCH)' build -quiet

test: project
	swift test --package-path Packages/SAMKit
	xcodebuild test -project SimpleAudioManager.xcodeproj -scheme SimpleAudioManager -destination 'platform=macOS,arch=$(ARCH)' -only-testing:DriverCoreTests -quiet

install: driver
	Scripts/install-driver.sh $(BUILD)/$(CONFIG)/SimpleAudioManager.driver

uninstall:
	Scripts/uninstall-driver.sh

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

run: app
	@# Refresh Launch Services so Finder and the Dock pick up icon changes.
	touch "$(APP)"
	$(LSREGISTER) -f "$(APP)"
	open "$(APP)"

release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=1.2.3" && exit 1)
	Scripts/build-release.sh $(VERSION)

logs:
	log stream --style compact --predicate 'subsystem == "dev.codejo.SimpleAudioManager.Driver"'

clean:
	rm -rf $(BUILD) dist
