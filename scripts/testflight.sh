#!/bin/zsh
# Archives the iPhone app (BackLogMobile), exports it for App Store Connect with the "BackLog iOS App
# Store" profiles and uploads it with the App Store Connect API key. Builds land in TestFlight.
#
# Usage: scripts/testflight.sh   (make testflight)
# Env: ASC_KEY_ID (default: the only ~/.appstoreconnect/private_keys/AuthKey_<id>.p8), ASC_ISSUER_ID
# (default: ~/.appstoreconnect/issuer_id). Bump CURRENT_PROJECT_VERSION in project.yml for each upload.
set -euo pipefail
cd "$(dirname "$0")/.."

team=8DR8DB9W22
out=build/ios
archive=$out/BackLog.xcarchive
keys=~/.appstoreconnect/private_keys
key_id="${ASC_KEY_ID:-}"
if [[ -z "$key_id" ]]; then
  found=($keys/AuthKey_*.p8(N))
  (( ${#found} == 1 )) || { echo "Set ASC_KEY_ID" >&2; exit 1; }
  key_id="${${found[1]:t:r}#AuthKey_}"
fi
issuer="${ASC_ISSUER_ID:-$(cat ~/.appstoreconnect/issuer_id)}"

rm -rf $archive $out/export
mkdir -p $out
[[ -f Shared/AppIcon.icon/icon.json ]] || swift scripts/make_icons.swift
xcodegen generate --quiet
xcodebuild -project BackLog.xcodeproj -scheme BackLogMobile -configuration Release \
  -destination 'generic/platform=iOS' -archivePath $archive -derivedDataPath build/iOSRelease -quiet archive

cat > $out/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.djui.BackLog</key><string>BackLog iOS App Store</string>
		<key>com.djui.BackLog.Share</key><string>BackLog Share iOS App Store</string>
	</dict>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath $archive -exportOptionsPlist $out/ExportOptions.plist -exportPath $out/export -quiet
xcrun altool --upload-app --type ios -f $out/export/BackLog.ipa --apiKey $key_id --apiIssuer $issuer
echo "Uploaded. It shows in TestFlight once App Store Connect has processed it (usually 5–15 minutes)."
