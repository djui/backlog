.PHONY: help icons generate test build run install dmg release testflight clean

help:
	@echo "make generate        Generate BackLog.xcodeproj (XcodeGen)"
	@echo "make test            Run BackLogCore unit tests"
	@echo "make build           Release build -> build/BackLog.app"
	@echo "make run             Debug build and launch"
	@echo "make install         Build, install to /Applications and restart"
	@echo "make icons           Render the app icon into Shared/AppIcon.icon"
	@echo "make dmg             Build build/BackLog-<version>.dmg"
	@echo "make release [PART=patch|minor|major] [NOTES='...']"
	@echo "make testflight      Archive the iPhone app and upload it to TestFlight"

generate:
	xcodegen generate

test:
	swift test --package-path Packages/BackLogCore

build:
	scripts/build_release.sh

run:
	scripts/run_debug.sh

install:
	scripts/install_local.sh

icons:
	swift scripts/make_icons.swift

dmg:
	scripts/make_dmg.sh

PART ?= patch
NOTES ?=
release:
	scripts/release.sh $(PART) "$(NOTES)"

testflight:
	scripts/testflight.sh

clean:
	rm -rf build BackLog.xcodeproj
