#!/usr/bin/env bash
# Builds Mutify.app. Pass --install to put it in /Applications and relaunch it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Mutify.app"
VERSION="1.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

echo "▸ Compiling"
swift build -c release --product Mutify
BIN="$(swift build -c release --show-bin-path)/Mutify"

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mutify"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mutify</string>
    <key>CFBundleDisplayName</key><string>Mutify</string>
    <key>CFBundleIdentifier</key><string>com.schmedu.mutify</string>
    <key>CFBundleExecutable</key><string>Mutify</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Eduard Uffelmann</string>
    <key>NSLocationUsageDescription</key>
    <string>macOS only reveals the name of the Wi-Fi network you're on to apps with location access. Mutify uses it to tell home from everywhere else. Your location never leaves this Mac.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>macOS only reveals the name of the Wi-Fi network you're on to apps with location access. Mutify uses it to tell home from everywhere else. Your location never leaves this Mac.</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>Mutify runs in the background and checks which Wi-Fi network you're on, which macOS treats as location data. Nothing is stored anywhere but this Mac.</string>
</dict>
</plist>
PLIST

echo "▸ Icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
PNG="$BUILD_DIR/icon-1024.png"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" "$PNG" >/dev/null
for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $pair
    sips -z "$1" "$1" "$PNG" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing"
# Prefer Developer ID (notarizable), fall back to a development cert, then ad-hoc.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
IDENTITY="$(printf '%s' "$IDENTITIES" | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(printf '%s' "$IDENTITIES" | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"' || true)"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
echo "  signed with: $IDENTITY"

if [[ $INSTALL -eq 1 ]]; then
    echo "▸ Installing to /Applications"
    pkill -x Mutify 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Mutify.app
    cp -R "$APP" /Applications/Mutify.app
    open -a /Applications/Mutify.app
    echo "  running from /Applications/Mutify.app"
else
    echo "▸ Built: $APP"
fi
