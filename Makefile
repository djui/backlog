.PHONY: help generate test build run install clean

help:
	@echo "make generate        Generate BackLog.xcodeproj (XcodeGen)"
	@echo "make test            Run BackLogCore unit tests"
	@echo "make build           Release build -> build/BackLog.app"
	@echo "make run             Debug build and launch"
	@echo "make install         Build, install to /Applications and restart"

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

clean:
	rm -rf build BackLog.xcodeproj
