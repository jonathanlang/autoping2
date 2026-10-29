#!/bin/bash
# Builds dist/Autoping.app with the Command Line Tools (no Xcode needed).
#   Scripts/build.sh            build only
#   Scripts/build.sh --install  build, install and (re)start the app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.0.0"
BUILD="$(date +%Y%m%d%H%M)"
APP="dist/Autoping.app"
BUNDLE_ID="de.jonathanlang.Autoping"

# --build-system native: SwiftPM's new default build system refuses to start while
# the Command Line Tools contain an incomplete SDK folder (MacOSX12.3.sdk).
SWIFT_BUILD=(swift build -c release --build-system native)
"${SWIFT_BUILD[@]}" 2>&1 | grep -v "build-system native' has been deprecated"
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path 2>/dev/null)"

if [ ! -f Support/AppIcon.icns ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    swift Scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Autoping" "$APP/Contents/MacOS/Autoping"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION, build $BUILD)"

if [ "${1:-}" = "--install" ]; then
    # The old autoping.app would collide with Autoping.app on the case-insensitive
    # file system, so install next to it in ~/Applications while it still exists.
    DEST="/Applications"
    if [ -d /Applications/autoping.app ] && \
       [ "$(defaults read /Applications/autoping.app/Contents/Info CFBundleIdentifier 2>/dev/null)" != "$BUNDLE_ID" ]; then
        DEST="$HOME/Applications"
        mkdir -p "$DEST"
    fi
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST/Autoping.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/Autoping.app"
    echo "Installed to $DEST/Autoping.app"
fi
