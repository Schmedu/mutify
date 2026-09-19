#!/usr/bin/env bash
# Builds Mutify.app.
#   --install   put it in /Applications and relaunch it
#   --release   Developer ID signed, notarized, stapled — a DMG others can run
# Override the marketing version with VERSION=1.1; the build number is the
# commit count either way.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Mutify.app"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
INSTALL=0
RELEASE=0
# `notarytool store-credentials` keeps the Apple ID and the app-specific
# password in the keychain, so no secret has to live in this script or in CI.
NOTARY_PROFILE="${MUTIFY_NOTARY_PROFILE:-mutify-notary}"

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --release) RELEASE=1 ;;
        -h|--help)
            echo "usage: build.sh [--install] [--release]"
            echo "  --install   put the app in /Applications and relaunch it"
            echo "  --release   Developer ID signed, notarized, stapled DMG"
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Worked out before anything is compiled: a release that can't be signed should
# fail in a second, not after a full build.
# Prefer Developer ID (notarizable), fall back to a development cert, then ad-hoc.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
IDENTITY="$(printf '%s' "$IDENTITIES" | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)"
DEVELOPER_ID=1
if [[ -z "$IDENTITY" ]]; then
    DEVELOPER_ID=0
    IDENTITY="$(printf '%s' "$IDENTITIES" | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"' || true)"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"

# A secure timestamp is fetched from Apple. Notarization insists on one; an
# everyday build shouldn't fail because the network is down.
TIMESTAMP="--timestamp=none"
[[ $DEVELOPER_ID -eq 1 ]] && TIMESTAMP="--timestamp"

if [[ $RELEASE -eq 1 ]]; then
    if [[ $DEVELOPER_ID -eq 0 ]]; then
        cat >&2 <<MSG
✗ No "Developer ID Application" certificate in this keychain.
  Every other kind of signature — development, ad-hoc — is refused by Gatekeeper
  on any Mac but the one that built it, so a release can't be made without it.
  The certificate comes with a paid Apple Developer Program membership:
  Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application.
  Signing identity found instead: ${IDENTITY}
MSG
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        cat >&2 <<MSG
✗ Notary credentials "${NOTARY_PROFILE}" aren't in the keychain — or Apple can't be reached.
  Store them once:
    xcrun notarytool store-credentials "${NOTARY_PROFILE}" \\
      --apple-id <apple id> --team-id <team id> --password <app-specific password>
  App-specific passwords: appleid.apple.com ▸ Sign-In and Security.
  Another profile name: MUTIFY_NOTARY_PROFILE=<name> ./Scripts/build.sh --release
MSG
        exit 1
    fi
    if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
        echo "⚠ Working tree isn't clean — the build number comes from the commit count."
    fi
fi

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
codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$APP"
echo "  signed with: $IDENTITY"

if [[ $RELEASE -eq 1 ]]; then
    ZIP="$BUILD_DIR/Mutify-$VERSION.zip"
    DMG="$BUILD_DIR/Mutify-$VERSION.dmg"

    # Apple's verdict arrives as text; anything but "Accepted" has to stop the
    # build, and the log id is the only way to find out what was wrong.
    notarize() {
        local out id
        out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
        printf '%s\n' "$out" | sed 's/^/    /'
        if ! grep -q "status: Accepted" <<<"$out"; then
            id="$(grep -m1 -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$out" || true)"
            echo "✗ Notarization failed. What Apple objected to:" >&2
            echo "    xcrun notarytool log ${id:-<submission id>} --keychain-profile $NOTARY_PROFILE" >&2
            exit 1
        fi
    }

    echo "▸ Notarizing the app (minutes, not seconds)"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    # The app is stapled too, not just the disk image: once it's dragged out of
    # the DMG it has to prove itself on a Mac that may well be offline.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "▸ Disk image"
    STAGE="$BUILD_DIR/dmg"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/Mutify.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Mutify" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    codesign --force $TIMESTAMP --sign "$IDENTITY" "$DMG"

    echo "▸ Notarizing the disk image"
    notarize "$DMG"
    xcrun stapler staple "$DMG"

    echo "▸ Checking it the way another Mac will"
    spctl -a -vvv "$APP" 2>&1 | sed 's/^/    /'
    spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 | sed 's/^/    /'
    xcrun stapler validate "$APP" >/dev/null && echo "    app: stapled"
    xcrun stapler validate "$DMG" >/dev/null && echo "    dmg: stapled"
    echo "  ✓ $DMG"
    echo "  ✓ $ZIP"
fi

if [[ $INSTALL -eq 1 ]]; then
    echo "▸ Installing to /Applications"
    pkill -x Mutify 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Mutify.app
    cp -R "$APP" /Applications/Mutify.app
    open -a /Applications/Mutify.app
    echo "  running from /Applications/Mutify.app"
elif [[ $RELEASE -eq 0 ]]; then
    echo "▸ Built: $APP"
fi
