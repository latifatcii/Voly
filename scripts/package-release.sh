#!/bin/bash
# Build a distributable Voly: a universal Release Voly.app in a DMG with an
# Applications shortcut, written to build/dist/Voly-<version>.dmg.
#
# Usage: scripts/package-release.sh [version]     (default: the app's own version)
#
# The app is ad-hoc signed: it has no expiry and embeds nobody's personal
# certificate, but it is not notarized, so the first launch on another Mac
# needs "Open" from the context menu (see the README).
#
# Nothing about the machine it was built on ships in the result: source
# paths are remapped at compile time and the debug symbol table (which
# records build directories) is stripped from the packaged copy.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/release"
DIST="$ROOT/build/dist"
APP="$DERIVED/Build/Products/Release/Voly.app"
VERSION_OVERRIDE=()
if [ -n "${1:-}" ]; then VERSION_OVERRIDE=("MARKETING_VERSION=$1"); fi

echo "== build (Release, universal)"
# A clean products directory, so the embed step can only pick up the Release
# simulator dylibs built right now.
rm -rf "$DERIVED/Build/Products"
xcodebuild -project "$ROOT/Voly.xcodeproj" -scheme Voly -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $ROOT=Voly" \
    "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$ROOT=Voly" \
    ${VERSION_OVERRIDE[@]+"${VERSION_OVERRIDE[@]}"} \
    build >"$DERIVED.log" 2>&1 || { tail -40 "$DERIVED.log"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "== stage"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Voly.app"
ln -s /Applications "$STAGE/Applications"
APP="$STAGE/Voly.app"
for DYLIB in VolyAgent.dylib VolyLaunchBridge.dylib; do
    [ -f "$APP/Contents/Resources/$DYLIB" ] || { echo "missing $DYLIB in the app bundle"; exit 1; }
done
# The Android agent (Voly/AndroidAgentPayload, built by AndroidAgent/build.sh).
ANDROID_AGENT="$(find "$APP/Contents/Resources" -name voly-agent.dex | head -1)"
[ -n "$ANDROID_AGENT" ] || { echo "missing the Android agent (voly-agent.dex) in the app bundle"; exit 1; }
"$ROOT/scripts/check-android-agent.sh" "$(dirname "$ANDROID_AGENT")" >/dev/null

# Strip debug symbol tables (keeping exported symbols, which the dylibs are
# loaded by), then sign again inside-out since stripping invalidates the
# build's signatures.
for BINARY in "$APP/Contents/Resources/VolyAgent.dylib" "$APP/Contents/Resources/VolyLaunchBridge.dylib" "$APP/Contents/MacOS/Voly"; do
    strip -S -x "$BINARY" 2>/dev/null
done
codesign --force --sign - "$APP/Contents/Resources/VolyAgent.dylib" "$APP/Contents/Resources/VolyLaunchBridge.dylib" 2>/dev/null
codesign --force --sign - --options runtime --entitlements "$ROOT/Voly/Voly.entitlements" "$APP" 2>/dev/null

echo "== verify"
codesign --verify --deep --strict "$APP"
echo "   version: $VERSION"
echo "   app:     $(lipo -archs "$APP/Contents/MacOS/Voly")"
echo "   agent:   $(lipo -archs "$APP/Contents/Resources/VolyAgent.dylib")"
echo "   bridge:  $(lipo -archs "$APP/Contents/Resources/VolyLaunchBridge.dylib")"
echo "   android: agent $(cat "$(dirname "$ANDROID_AGENT")/voly-agent.version")"
LEAKS=$(strings - "$APP/Contents/MacOS/Voly" "$APP/Contents/Resources/"*.dylib | grep -c "$HOME" || true)
if [ "$LEAKS" != "0" ]; then echo "   warning: $LEAKS strings still contain $HOME"; fi

echo "== package"
mkdir -p "$DIST"
DMG="$DIST/Voly-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Voly $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
shasum -a 256 "$DMG" | awk '{print "sha256 " $1}'
