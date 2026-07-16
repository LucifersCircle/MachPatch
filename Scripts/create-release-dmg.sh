#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
DESTINATION="${1:-$ROOT/dist}"
INFO_PLIST="$ROOT/Resources/AppIcon/Info.plist"
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
VERSION="${2:-$PLIST_VERSION}"
ARCHITECTURE="${MACOS_ARCHITECTURE:-arm64}"
APP="$DESTINATION/MachPatch.app"
STAGING="$DESTINATION/.MachPatch-dmg-staging"
DMG="$DESTINATION/MachPatch-$VERSION-macOS-$ARCHITECTURE.dmg"
CHECKSUM="$DMG.sha256"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    echo "Release version is not valid: $VERSION" >&2
    exit 2
fi
if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
    echo "Release version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
    exit 3
fi

mkdir -p "$DESTINATION"
MACOS_ARCHITECTURE="$ARCHITECTURE" "$ROOT/Scripts/package-app.sh" "$DESTINATION"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$STAGING"
mkdir -p "$STAGING"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/MachPatch.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG" "$CHECKSUM"
hdiutil create \
    -volname "MachPatch $VERSION" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    "$DMG"
hdiutil verify "$DMG"

(
    cd "$DESTINATION"
    shasum -a 256 "${DMG:t}" > "${CHECKSUM:t}"
)

echo "Created $DMG"
echo "Created $CHECKSUM"
