#!/usr/bin/env bash
# Builds a Release archive and exports build/BackLog.app.
#
#   scripts/build_release.sh              # signed with your Apple Development identity (or ad-hoc)
#   scripts/build_release.sh --notarize   # Developer ID export + notarization (needs NOTARY_PROFILE)
#
# Env: DEVELOPMENT_TEAM overrides the team ID detected from the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

BUILD_DIR=build
ARCHIVE="$BUILD_DIR/BackLog.xcarchive"
APP="$BUILD_DIR/BackLog.app"

[[ -f Shared/AppIcon.icon/icon.json ]] || swift scripts/make_icons.swift
xcodegen generate --quiet

# Signing is manual (project.yml): Developer ID with the "BackLog Developer ID" profile, which
# carries the iCloud entitlement.
team=8DR8DB9W22

rm -rf "$ARCHIVE" "$APP"
mkdir -p "$BUILD_DIR"
xcodebuild \
  -project BackLog.xcodeproj \
  -scheme BackLog \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -archivePath "$ARCHIVE" \
  ARCHS=arm64 \
  -quiet \
  archive

if [[ "$NOTARIZE" == 1 ]]; then
  source scripts/notary.sh
  (( ${#notary_args[@]} )) || { echo "No notarytool profile or App Store Connect API key" >&2; exit 1; }
  security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
  cat >"$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>${team}</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key>
  <dict><key>com.djui.BackLog</key><string>BackLog Developer ID</string></dict>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$BUILD_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet
  ditto -c -k --keepParent "$APP" "$BUILD_DIR/BackLog-notarize.zip"
  xcrun notarytool submit "$BUILD_DIR/BackLog-notarize.zip" "${notary_args[@]}" --no-s3-acceleration --wait
  # Stapling fetches the ticket from Apple's CDN, which sometimes drops the connection; retry.
  for attempt in 1 2 3 4 5; do xcrun stapler staple "$APP" && break; [[ $attempt == 5 ]] && exit 1; sleep 10; done
  rm -f "$BUILD_DIR/BackLog-notarize.zip"
else
  ditto "$ARCHIVE/Products/Applications/BackLog.app" "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "Built $APP"
