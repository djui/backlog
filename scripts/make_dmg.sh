#!/usr/bin/env bash
# Packs build/BackLog.app into build/BackLog-<version>.dmg (drag-to-Applications layout).
# Signs and notarizes the DMG too when a Developer ID identity and NOTARY_PROFILE are available.
#
#   scripts/make_dmg.sh            # uses an existing build/BackLog.app, or builds one
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/BackLog.app
[[ -d "$APP" ]] || scripts/build_release.sh

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/BackLog-$version.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/BackLog.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "BackLog $version" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null

identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1 || true)"
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --timestamp "$DMG"
  source scripts/notary.sh
  if (( ${#notary_args[@]} )); then
    xcrun notarytool submit "$DMG" "${notary_args[@]}" --no-s3-acceleration --wait
    # Stapling fetches the ticket from Apple's CDN, which sometimes drops the connection; retry.
    for attempt in 1 2 3 4 5; do xcrun stapler staple "$DMG" && break; [[ $attempt == 5 ]] && exit 1; sleep 10; done
  fi
else
  echo "No Developer ID identity: the DMG is not signed (fine for local use)" >&2
fi
echo "Built $DMG"
