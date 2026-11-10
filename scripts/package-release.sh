#!/bin/bash
# Build a distributable Voly: a universal Release Voly.app in a DMG with an
# Applications shortcut, written to build/dist/Voly-<version>.dmg.
#
# Usage: scripts/package-release.sh [version]     (default: the app's own version)
#
# The app is ad-hoc signed: it has no expiry and embeds nobody's personal
# certificate, but it is not notarized, so the first launch on another Mac
# needs "Open" from the context menu (see the README).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/release"
DIST="$ROOT/build/dist"
APP="$DERIVED/Build/Products/Release/Voly.app"

echo "== build (Release, universal)"
# A clean products directory, so the embed step can only pick up the Release
# simulator dylibs built right now.
rm -rf "$DERIVED/Build/Products"
xcodebuild -project "$ROOT/Voly.xcodeproj" -scheme Voly -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build >"$DERIVED.log" 2>&1 || { tail -40 "$DERIVED.log"; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"

echo "== verify"
for DYLIB in VolyAgent.dylib VolyLaunchBridge.dylib; do
    [ -f "$APP/Contents/Resources/$DYLIB" ] || { echo "missing $DYLIB in the app bundle"; exit 1; }
done
codesign --verify --deep --strict "$APP"
echo "   app:    $(lipo -archs "$APP/Contents/MacOS/Voly")"
echo "   agent:  $(lipo -archs "$APP/Contents/Resources/VolyAgent.dylib")"
echo "   bridge: $(lipo -archs "$APP/Contents/Resources/VolyLaunchBridge.dylib")"

echo "== package"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Voly.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
DMG="$DIST/Voly-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Voly $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
shasum -a 256 "$DMG" | awk '{print "sha256 " $1}'
