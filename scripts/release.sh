#!/usr/bin/env bash
# Tests, bumps the version, builds a DMG, updates the Sparkle appcast, tags, pushes and publishes a
# GitHub Release.
#
#   scripts/release.sh [patch|minor|major] ["release notes summary"]
#
# Needs gh logged in, the Sparkle signing key (run Sparkle's generate_keys once; put the public key
# in BackLog/Info.plist as SUPublicEDKey), a Developer ID Application certificate and a notarytool
# keychain profile (xcrun notarytool store-credentials). NOTARY_PROFILE names the profile and
# defaults to "murmur" (any notarytool profile for the team works). Releases are always notarized: the script stops before building otherwise.
# The first release ships the version already in project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

PART="${1:-patch}"
SUMMARY="${2:-}"
case "$PART" in patch | minor | major) ;; *) echo "usage: $0 [patch|minor|major] [summary]" >&2; exit 2 ;; esac

command -v gh >/dev/null || { echo "gh is required (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated; run: gh auth login" >&2; exit 1; }
export NOTARY_PROFILE="${NOTARY_PROFILE:-murmur}"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "No Developer ID Application certificate in the keychain; releases must be notarized" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "notarytool profile \"$NOTARY_PROFILE\" doesn't work; run xcrun notarytool store-credentials $NOTARY_PROFILE" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' BackLog/Info.plist >/dev/null 2>&1 \
  || { echo "Add SUPublicEDKey to BackLog/Info.plist first (see Sparkle's generate_keys)" >&2; exit 1; }

# generate_appcast builds the appcast and delta updates from the DMGs in dist/. A fresh checkout
# has none, so start from the latest release's appcast and DMG.
latest_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [[ -n "$latest_tag" && ! -f "dist/BackLog-${latest_tag#v}.dmg" ]]; then
  echo "Fetching $latest_tag's appcast and DMG into dist/…" >&2
  mkdir -p dist
  gh release download "$latest_tag" --dir dist --clobber --pattern appcast.xml --pattern "BackLog-${latest_tag#v}.dmg"
fi

echo "Running tests…" >&2
swift test --package-path Packages/BackLogCore

current="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' project.yml | head -1)"
build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\).*/\1/p' project.yml | head -1)"
previous_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"

if [[ -z "$previous_tag" ]]; then
  version="$current"
else
  IFS=. read -r major minor patch <<<"$current"
  case "$PART" in
    major) version="$((major + 1)).0.0" ;;
    minor) version="$major.$((minor + 1)).0" ;;
    patch) version="$major.$minor.$((patch + 1))" ;;
  esac
  build=$((build + 1))
fi
tag="v$version"
git rev-parse "$tag" >/dev/null 2>&1 && { echo "Tag $tag already exists" >&2; exit 1; }

sed -i '' -E "s/^( *MARKETING_VERSION: *)\"?[0-9.]+\"?/\1\"$version\"/" project.yml
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: *)[0-9]+/\1$build/" project.yml

echo "Building $tag…" >&2
scripts/build_release.sh --notarize
scripts/make_dmg.sh

mkdir -p dist
dmg="dist/BackLog-$version.dmg"
cp -f "build/BackLog-$version.dmg" "$dmg"

# Gatekeeper must accept both as notarized before anything is published.
spctl -a -t exec build/BackLog.app >/dev/null 2>&1 \
  || { echo "build/BackLog.app is not notarized; not releasing" >&2; exit 1; }
spctl -a -t open --context context:primary-signature "$dmg" >/dev/null 2>&1 \
  || { echo "$dmg is not notarized; not releasing" >&2; exit 1; }

generate_appcast="$(find build/DerivedData/SourcePackages/artifacts -path '*Sparkle*/bin/generate_appcast' -type f | head -1)"
[[ -x "$generate_appcast" ]] || { echo "generate_appcast not found; build once so SwiftPM fetches Sparkle" >&2; exit 1; }
"$generate_appcast" --account backlog \
  --download-url-prefix "https://github.com/djui/backlog/releases/download/$tag/" \
  -o dist/appcast.xml dist
# generate_appcast gives every full DMG this release's prefix; each lives in its own release.
sed -i '' -E 's#releases/download/v[0-9.]+/BackLog-([0-9.]+)\.dmg#releases/download/v\1/BackLog-\1.dmg#g' dist/appcast.xml

git add -A
git commit -m "Release $tag${SUMMARY:+: $SUMMARY}" || true
git tag -a "$tag" -m "BackLog $version"
# HEAD:main so a release from a worktree branch lands on main; --atomic so a rejected main doesn't
# push the tag alone.
git push --atomic origin HEAD:main --tags

notes="${SUMMARY:-BackLog $version}"
if [[ -n "$previous_tag" ]]; then
  log="$(git log "$previous_tag..HEAD" --pretty='- %s' --no-merges | grep -v '^- Release v' || true)"
  notes="$notes"$'\n\n'"$log"
fi
# generate_appcast writes delta updates as BackLog<build>-<from build>.delta; the appcast links them.
shopt -s nullglob
deltas=(dist/BackLog"$build"-*.delta)
shopt -u nullglob
gh release create "$tag" "$dmg" dist/appcast.xml ${deltas[@]+"${deltas[@]}"} --title "BackLog $version" --notes "$notes"
echo "Released $tag"
