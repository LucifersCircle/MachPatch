#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
DESTINATION="${1:-$ROOT/dist}"
APP="$DESTINATION/MachPatch.app"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
ARCHITECTURE="${MACOS_ARCHITECTURE:-}"
MODULE_CACHE="$ROOT/.build/ModuleCache"

cd "$ROOT"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

BUILD_ARGUMENTS=(--configuration "$CONFIGURATION" --product MachPatchApp)
PATH_ARGUMENTS=(--configuration "$CONFIGURATION")
if [[ -n "$ARCHITECTURE" ]]; then
    case "$ARCHITECTURE" in
        arm64|x86_64) ;;
        *)
            echo "Unsupported macOS architecture: $ARCHITECTURE" >&2
            exit 2
            ;;
    esac
    TRIPLE="$ARCHITECTURE-apple-macosx14.0"
    BUILD_ARGUMENTS+=(--triple "$TRIPLE")
    PATH_ARGUMENTS+=(--triple "$TRIPLE")
fi

swift build "${BUILD_ARGUMENTS[@]}"
BIN_DIRECTORY="$(swift build "${PATH_ARGUMENTS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIRECTORY/MachPatchApp" "$APP/Contents/MacOS/MachPatch"
cp "$ROOT/Resources/AppIcon/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon/MachPatch.icns" "$APP/Contents/Resources/MachPatch.icns"
chmod 755 "$APP/Contents/MacOS/MachPatch"
codesign --force --deep --sign "$IDENTITY" "$APP"

if [[ -n "$ARCHITECTURE" ]]; then
    BUILT_ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/MachPatch")"
    if [[ "$BUILT_ARCHITECTURES" != "$ARCHITECTURE" ]]; then
        echo "Packaged executable architecture is $BUILT_ARCHITECTURES; expected $ARCHITECTURE" >&2
        exit 3
    fi
fi

echo "Packaged $APP"
