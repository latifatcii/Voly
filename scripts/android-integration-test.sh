#!/bin/bash
# End-to-end check of the Android side against a running emulator, without
# Voly.app: volyctl drives the same code the app uses (adb discovery, the
# agent installer, the wire protocol) against the sample app.
#
# Usage: scripts/android-integration-test.sh [<adb serial>]   (default: the only emulator)
#
# Needs: adb on PATH (or ANDROID_HOME), a booted emulator running Android 8
# or later, and a JDK for building the sample app the first time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE=com.example.volysample
APK="$ROOT/SampleAppAndroid/app/build/outputs/apk/debug/app-debug.apk"

if ! command -v adb >/dev/null 2>&1; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  export PATH="$SDK/platform-tools:$PATH"
fi
command -v adb >/dev/null 2>&1 || { echo "adb not found"; exit 1; }

SERIAL="${1:-$(adb devices | awk '$2 == "device" && $1 ~ /^emulator-/ { print $1 }' | head -1)}"
[ -n "$SERIAL" ] || { echo "no booted emulator; pass a serial"; exit 1; }
echo "== device $SERIAL"

echo "== build volyctl"
swift build --package-path "$ROOT/Packages/VolyCore" --product volyctl >/dev/null
VOLYCTL="$(swift build --package-path "$ROOT/Packages/VolyCore" --show-bin-path)/volyctl"
ctl() { "$VOLYCTL" android "$@" --agent-dir "$ROOT/Voly/AndroidAgentPayload"; }
send() { ctl send "$SERIAL" "$PACKAGE" "$1"; }

FAILED=0
check() { # check <what> <text> <needle>
  if grep -q -- "$3" <<<"$2"; then echo "ok   $1"; else echo "FAIL $1 (no \"$3\")"; FAILED=1; fi
}

if [ ! -f "$APK" ]; then
  echo "== build the sample app"
  (cd "$ROOT/SampleAppAndroid" && ./gradlew --quiet :app:assembleDebug)
fi
echo "== install and launch the sample app"
adb -s "$SERIAL" install -r "$APK" >/dev/null
adb -s "$SERIAL" shell am force-stop "$PACKAGE"
adb -s "$SERIAL" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
sleep 3

echo "== discovery and attach"
APPS="$(ctl apps "$SERIAL")"
echo "$APPS"
check "the sample app gets the agent" "$APPS" "$PACKAGE pid=.* inspectable"

echo "== protocol"
check "ping" "$(send '{"ping":{}}')" "pong"
check "view tree" "$(send '{"getHierarchy":{}}')" "DecorView"
DESCRIBE='{"describeScreen":{"_0":{"includeHidden":false,"checkLayout":true,"includeAccessibility":true}}}'
check "screen description" "$(send "$DESCRIBE")" "demo_list"
check "navigation state" "$(send '{"navigationState":{}}')" "MainActivity"
check "languages" "$(send '{"localizationState":{}}')" '"code" : "tr"'
check "preferences" "$(send '{"userDefaultsList":{}}')" "flag_enabled"

echo "== deep link, Compose, navigation"
check "deep link" "$(send '{"openURL":{"url":"volysample://demo/compose"}}')" '"success" : true'
sleep 2
check "Compose semantics" "$(send "$DESCRIBE")" "compose.button"
check "pop" "$(send '{"navigate":{"_0":"pop"}}')" '"performed" : true'
sleep 1

echo "== layout problems are flagged"
send '{"openURL":{"url":"volysample://demo/problems"}}' >/dev/null
sleep 2
PROBLEMS="$(send "$DESCRIBE")"
check "truncated text" "$PROBLEMS" "truncated"
check "zero size" "$PROBLEMS" "zeroSize"
check "off screen" "$PROBLEMS" "offscreen"

echo "== screenshots"
OUT="$(mktemp -d)"
ctl screenshot "$SERIAL" "$PACKAGE" app "$OUT/app.png" >/dev/null
ctl screenshot "$SERIAL" "$PACKAGE" device "$OUT/device.png" >/dev/null
for name in app device; do
  if [ "$(head -c 4 "$OUT/$name.png" | xxd -p)" = "89504e47" ]; then echo "ok   $name screenshot ($OUT/$name.png)"
  else echo "FAIL $name screenshot"; FAILED=1; fi
done

echo "== nothing is left behind"
PORT="$(adb -s "$SERIAL" forward --list | awk -v s="$SERIAL" '$1 == s && $3 ~ /voly-agent/ { sub("tcp:", "", $2); print $2 }' | tail -1)"
if [ -n "$PORT" ]; then echo "FAIL forwarded ports should be released after each command"; FAILED=1; else echo "ok   no port is left forwarded"; fi

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
