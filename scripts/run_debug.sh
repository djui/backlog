#!/usr/bin/env bash
# Debug build and launch.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project BackLog.xcodeproj -scheme BackLog -configuration Debug \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -quiet build
pkill -x BackLog 2>/dev/null || true
open build/DerivedData/Build/Products/Debug/BackLog.app
