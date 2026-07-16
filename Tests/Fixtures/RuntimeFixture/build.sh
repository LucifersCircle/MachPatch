#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h}"
OUTPUT="${1:-$ROOT/Build}"
APP="$OUTPUT/MachPatchRuntimeFixture.app"
FRAMEWORK="$APP/Frameworks/MPFixtureKit.framework"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
COMMON=(
    -arch arm64
    -isysroot "$SDK"
    -miphoneos-version-min=15.0
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -framework Foundation
    -framework UIKit
    -framework CoreGraphics
)

rm -rf "$APP"
mkdir -p "$FRAMEWORK"

"$CLANG" "${COMMON[@]}" \
    -dynamiclib \
    -Wl,-install_name,@rpath/MPFixtureKit.framework/MPFixtureKit \
    "$ROOT/Sources/MPFixtureKit.m" \
    -o "$FRAMEWORK/MPFixtureKit"
cp "$ROOT/FrameworkInfo.plist" "$FRAMEWORK/Info.plist"
codesign --force --sign - "$FRAMEWORK"

"$CLANG" "${COMMON[@]}" \
    -Wl,-rpath,@executable_path/Frameworks \
    "$ROOT/Sources/FixtureApp.m" \
    -o "$APP/MachPatchRuntimeFixture"
cp "$ROOT/AppInfo.plist" "$APP/Info.plist"
codesign --force --deep --sign - "$APP"

echo "$APP"
