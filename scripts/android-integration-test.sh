#!/bin/bash
# End-to-end check of the Android side against a running emulator, without
# Voly.app: volyctl drives the same code the app uses (adb discovery, the
# agent installer, the wire protocol) against the sample app.
#
# Usage: scripts/android-integration-test.sh [<adb serial>]   (default: the only emulator)
#
# Needs: adb on PATH (or ANDROID_HOME), a booted emulator running Android 8
# or later, and a JDK for building the sample app the first time. Quit
# Voly.app first: both would attach to the same app and cut each other off.
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
# VOLY_ANDROID_AGENT_DIR: test another build of the agent than the bundled one.
AGENT_DIR="${VOLY_ANDROID_AGENT_DIR:-$ROOT/Voly/AndroidAgentPayload}"
ctl() { "$VOLYCTL" android "$@" --agent-dir "$AGENT_DIR"; }
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
# The sample's own data, so its preferences are the ones it creates at first launch.
adb -s "$SERIAL" shell pm clear "$PACKAGE" >/dev/null
adb -s "$SERIAL" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
# A cold emulator takes its time to start the process and draw the first screen.
for _ in $(seq 1 40); do
  if adb -s "$SERIAL" shell dumpsys activity activities | grep -q "ResumedActivity.*$PACKAGE"; then break; fi
  sleep 0.5
done
sleep 1

echo "== discovery and attach"
# A process that has only just started is not listed under its package name yet.
for _ in $(seq 1 10); do
  APPS="$(ctl apps "$SERIAL")"
  if grep -q "$PACKAGE pid=.* inspectable" <<<"$APPS"; then break; fi
  sleep 1
done
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
check "Compose content in the view tree" "$(send '{"getHierarchy":{}}')" '"accessibilityIdentifier" : "compose.button"'
check "pop" "$(send '{"navigate":{"_0":"pop"}}')" '"performed" : true'
sleep 1

echo "== layout problems are flagged"
send '{"openURL":{"url":"volysample://demo/problems"}}' >/dev/null
sleep 2
PROBLEMS="$(send "$DESCRIBE")"
check "truncated text" "$PROBLEMS" "truncated"
check "zero size" "$PROBLEMS" "zeroSize"
check "off screen" "$PROBLEMS" "offscreen"

echo "== a card keeps its shape when it is recolored"
view_id() { # view_id <screen description json> <android:id>
  python3 -c '
import json, sys
def walk(node):
    yield node
    for child in node.get("children") or []:
        yield from walk(child)
screen = json.loads(sys.argv[1])["screenDescription"]["_0"]
print(next((n["id"] for root in screen["roots"] for n in walk(root) if n.get("accessibilityIdentifier") == sys.argv[2]), ""))
' "$1" "$2"
}
# "rounded" when the corner pixel of a PNG is not the color of its middle, else "square".
corner_shape() {
  python3 -c '
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
width, height, depth, kind = struct.unpack(">IIBB", data[16:26])
channels = {2: 3, 6: 4}[kind]
position, packed = 8, b""
while position < len(data):
    length, tag = struct.unpack(">I4s", data[position:position + 8])
    if tag == b"IDAT": packed += data[position + 8:position + 8 + length]
    position += 12 + length
raw, stride = zlib.decompress(packed), width * channels
rows, previous, offset = [], bytearray(stride), 0
for _ in range(height):
    kind_of_filter, line = raw[offset], bytearray(raw[offset + 1:offset + 1 + stride])
    offset += 1 + stride
    for i in range(stride):
        left = line[i - channels] if i >= channels else 0
        up, upper_left = previous[i], previous[i - channels] if i >= channels else 0
        if kind_of_filter == 1: line[i] = (line[i] + left) & 255
        elif kind_of_filter == 2: line[i] = (line[i] + up) & 255
        elif kind_of_filter == 3: line[i] = (line[i] + (left + up) // 2) & 255
        elif kind_of_filter == 4:
            estimate = left + up - upper_left
            nearest = min((abs(estimate - left), 0, left), (abs(estimate - up), 1, up), (abs(estimate - upper_left), 2, upper_left))[2]
            line[i] = (line[i] + nearest) & 255
    rows.append(line)
    previous = line
pixel = lambda x, y: tuple(rows[y][x * channels:x * channels + 3])
corner, middle = pixel(1, 1), pixel(width // 4, height // 2)
print("square" if max(abs(a - b) for a, b in zip(corner, middle)) < 12 else "rounded")
' "$1"
}
# The Material card has a shape drawable of its own; the plain one paints itself.
for CARD_ID in problems_card problems_plain_card; do
  CARD="$(view_id "$PROBLEMS" "$CARD_ID")"
  if [ -z "$CARD" ]; then echo "FAIL $CARD_ID is on the problems screen"; FAILED=1; continue; fi
  send "{\"setProperty\":{\"_0\":{\"objectID\":$CARD,\"scope\":\"view\",\"change\":{\"property\":\"backgroundColor\",\"value\":{\"color\":{\"_0\":{\"red\":1,\"green\":0.9,\"blue\":0.6,\"alpha\":1}}}}}}}" >/dev/null
  AFTER="$(send "{\"describeScreen\":{\"_0\":{\"rootID\":$CARD,\"maxDepth\":0}}}")"
  check "$CARD_ID took the color" "$AFTER" '"backgroundColor" : "#FFE699FF"'
  SHOT="$(mktemp -d)/card.png"
  ctl screenshot "$SERIAL" "$PACKAGE" "view:$CARD" "$SHOT" >/dev/null
  check "$CARD_ID still has rounded corners" "$(corner_shape "$SHOT")" "rounded"
done

echo "== preferences keep the type the app reads them with"
setpref() { # setpref <suite> <key> <PropValue json>
  send "{\"userDefaultsSet\":{\"_0\":{\"suite\":\"$1\",\"key\":\"$2\",\"value\":$3}}}" 2>&1 || true
}
stored() { sleep 1; adb -s "$SERIAL" shell "run-as $PACKAGE cat shared_prefs/$1.xml"; }
MAIN="${PACKAGE}_preferences"
setpref "$MAIN" display_name '{"bool":{"_0":true}}' >/dev/null
check "a boolean sent to a string key is stored as text" "$(stored "$MAIN")" '<string name="display_name">true</string>'
check "letters sent to an int key are refused" "$(setpref "$MAIN" counter '{"string":{"_0":"abc"}}')" "holds an int"
setpref "$MAIN" counter '{"string":{"_0":"7"}}' >/dev/null
check "digits sent as text to an int key are stored as an int" "$(stored "$MAIN")" '<int name="counter" value="7"'
setpref "$MAIN" first_launch_at '{"int":{"_0":9007199254740993}}' >/dev/null
check "a long keeps every digit" "$(stored "$MAIN")" '<long name="first_launch_at" value="9007199254740993"'
check "2 is not a value for a boolean key" "$(setpref "$MAIN" flag_enabled '{"int":{"_0":2}}')" "holds a boolean"
check "and the boolean is still one" "$(stored "$MAIN")" '<boolean name="flag_enabled"'
setpref voly_sample_settings text_scale '{"int":{"_0":2}}' >/dev/null
check "a whole number sent to a float key stays a float" "$(stored voly_sample_settings)" '<float name="text_scale" value="2.0"'
check "a set of strings is not overwritten" "$(setpref voly_sample_settings favorite_demos '{"string":{"_0":"x"}}')" "set of strings"
check "and is still a set" "$(stored voly_sample_settings)" '<set name="favorite_demos"'
setpref "$MAIN" display_name '{"string":{"_0":"Voly Tester"}}' >/dev/null
setpref "$MAIN" counter '{"int":{"_0":0}}' >/dev/null

if [ "$(adb -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')" -ge 33 ]; then
  echo "== a language chosen outside Voly is not Voly's to report or to clear"
  language() { # language <tag or null> <direction mode>
    local tag=null; [ "$1" = null ] || tag="\"$1\""
    send "{\"setLocalizationOverride\":{\"_0\":{\"language\":$tag,\"layoutDirectionMode\":\"$2\",\"refreshUI\":true}}}"
  }
  app_locales() { adb -s "$SERIAL" shell cmd locale get-app-locales "$PACKAGE" | tr -d '\r'; }
  adb -s "$SERIAL" shell cmd locale set-app-locales "$PACKAGE" --locales fr >/dev/null
  sleep 2
  STATE="$(send '{"localizationState":{}}')"
  if grep -q '"activeOverride"' <<<"$STATE"; then echo "FAIL a language set in Settings is not reported as Voly's override"; FAILED=1
  else echo "ok   a language set in Settings is not reported as Voly's override"; fi
  language null leftToRight >/dev/null
  check "changing only the layout direction leaves that language alone" "$(app_locales)" "\[fr\]"
  SET="$(language tr system)"
  check "a language set through Voly is the override" "$SET" '"activeOverride" : "tr"'
  check "the device's own language is still reported as the system's" "$SET" '"systemLanguage" : "en'
  check "the app is in it" "$(app_locales)" "\[tr\]"
  RESET="$(language null system)"
  if grep -q '"activeOverride"' <<<"$RESET"; then echo "FAIL undoing it leaves no override"; FAILED=1
  else echo "ok   undoing it leaves no override"; fi
  check "and puts back the language from before" "$(app_locales)" "\[fr\]"
  adb -s "$SERIAL" shell cmd locale set-app-locales "$PACKAGE" >/dev/null
  sleep 2
fi

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
