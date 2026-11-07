#!/bin/zsh
# Builds TinyMacro.app into ./build
#   ./build.sh           build for this Mac
#   ./build.sh release   universal (Apple Silicon + Intel) build + build/TinyMacro.zip
set -euo pipefail
cd "$(dirname "$0")"

APP=build/TinyMacro.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

MODE=${1:-dev}
ARCHS=($(uname -m))
[[ "$MODE" == "release" ]] && ARCHS=(arm64 x86_64)

BINS=()
for arch in $ARCHS; do
    swiftc -O -swift-version 5 \
        -target "$arch-apple-macos14.0" \
        Sources/main.swift \
        -framework Cocoa -framework Carbon \
        -o "build/TinyMacro-$arch"
    BINS+=("build/TinyMacro-$arch")
done
lipo -create $BINS -output "$APP/Contents/MacOS/TinyMacro"
rm -f $BINS

cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [[ -n "${SIGN_IDENTITY:-}" ]] || security find-identity -p codesigning 2>/dev/null | grep -q "TinyMacro Local Signing"; then
    # Stable certificate: macOS remembers permissions across rebuilds.
    codesign --force --deep --sign "${SIGN_IDENTITY:-TinyMacro Local Signing}" "$APP"
else
    # Ad-hoc, but pin the identity to the bundle ID so rebuilds look like the same app.
    codesign --force --deep --sign - -r='designated => identifier "com.tinymacro.app"' "$APP"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/TinyMacro"))"

if [[ "$MODE" == "release" ]]; then
    rm -f build/TinyMacro.zip
    ditto -c -k --keepParent "$APP" build/TinyMacro.zip
    echo "Packaged build/TinyMacro.zip ($(du -h build/TinyMacro.zip | cut -f1))"
fi
