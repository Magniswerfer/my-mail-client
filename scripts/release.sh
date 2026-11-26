#!/bin/bash
# Mac release (SPEC §17): archive → Developer ID export → notarize + staple the app → .dmg →
# notarize + staple the .dmg → Sparkle appcast → GitHub release.
#
#   scripts/release.sh            build everything into App/build-release/out/<version>/
#   scripts/release.sh --publish  …and publish it as GitHub release v<version>
#
# The version is MARKETING_VERSION in App/project.yml; bump it (and CURRENT_PROJECT_VERSION,
# which Sparkle compares) before each release.
#
# Needs, on this Mac: the "Developer ID Application: Creative Oak ApS" certificate, a notarytool
# keychain profile named "notary" (xcrun notarytool store-credentials notary), Sparkle's EdDSA
# key in the login keychain (created by Sparkle's generate_keys), and gh signed in.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PUBLISH=false
[[ "${1:-}" == "--publish" ]] && PUBLISH=true

REPO="Magniswerfer/my-mail-client"
IDENTITY="Developer ID Application: Creative Oak ApS (493257NQK3)"
NOTARY_PROFILE="notary"
DERIVED="App/build-release"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' App/project.yml)"
BUILD="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' App/project.yml)"
TAG="v$VERSION"
OUT="$DERIVED/out/$VERSION"
APP="$OUT/export/Tidings.app"
DMG="$OUT/Tidings-$VERSION.dmg"
FEED="$OUT/feed"

step() { printf '\n==> %s\n' "$*"; }

[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "No version in App/project.yml"; exit 1; }
if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working tree has changes; commit them first so the release matches a commit."; exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists; bump MARKETING_VERSION and CURRENT_PROJECT_VERSION."; exit 1
fi

step "Tidings $VERSION ($BUILD)"
rm -rf "$OUT"
mkdir -p "$OUT"
(cd App && xcodegen generate >/dev/null)

step "Archive"
# arm64 for every target, packages too: MailEngine's Float16 embeddings don't exist on Intel.
xcodebuild archive -project App/Tidings.xcodeproj -scheme Tidings -configuration Release \
    -derivedDataPath "$DERIVED" -archivePath "$OUT/Tidings.xcarchive" \
    -allowProvisioningUpdates -quiet ARCHS=arm64

step "Export with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/Tidings.xcarchive" \
    -exportOptionsPlist App/ExportOptions.plist -exportPath "$OUT/export" \
    -allowProvisioningUpdates -quiet
codesign --verify --deep --strict "$APP"

step "Notarize the app"
ditto -c -k --keepParent "$APP" "$OUT/Tidings.zip"
xcrun notarytool submit "$OUT/Tidings.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/Tidings.zip"

step "Disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tidings.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tidings" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarize the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

step "Sparkle appcast"
mkdir -p "$FEED"
cp "$DMG" "$FEED/"
# Earlier versions stay in the feed: start from the appcast on the latest release, if any.
gh release download --repo "$REPO" --pattern appcast.xml --dir "$FEED" 2>/dev/null || true
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" \
    "$FEED"

echo
echo "Built: $DMG"
echo "Feed:  $FEED/appcast.xml"

if $PUBLISH; then
    step "Publish $TAG"
    git push origin HEAD
    gh release create "$TAG" --repo "$REPO" --target "$(git rev-parse HEAD)" \
        --title "Tidings $VERSION" --generate-notes \
        "$DMG" "$FEED/appcast.xml"
    echo "Published: https://github.com/$REPO/releases/tag/$TAG"
fi
