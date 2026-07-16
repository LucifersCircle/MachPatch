#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
DESTINATION="${1:-$ROOT/dist}"
APP="$DESTINATION/MachPatch.app"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
MODULE_CACHE="$ROOT/.build/ModuleCache"

cd "$ROOT"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
swift build --configuration "$CONFIGURATION" --product MachPatchApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIGURATION/MachPatchApp" "$APP/Contents/MacOS/MachPatch"
cp "$ROOT/Resources/AppIcon/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon/MachPatch.icns" "$APP/Contents/Resources/MachPatch.icns"
chmod 755 "$APP/Contents/MacOS/MachPatch"
codesign --force --deep --sign "$IDENTITY" "$APP"

echo "Packaged $APP"
