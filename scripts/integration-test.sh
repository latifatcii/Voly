#!/bin/bash
# End-to-end check of simulator runtime integration against a real, booted
# iOS Simulator. Builds the simulator dylibs and SampleApp, then drives the
# same code paths Voly.app uses through `volyctl`:
#
#   launch bridge load -> environment-preserving injection -> debugger-style
#   launch -> authenticated agent -> localization, navigation, screenshots,
#   source lookup -> policy -> clean disable.
#
# Usage: scripts/integration-test.sh <booted-simulator-udid>
#
# Set VOLY_TEST_RUNTIME_DIR to a directory holding VolyAgent.dylib and
# VolyLaunchBridge.dylib (e.g. a packaged Voly.app/Contents/Resources) to
# test those exact dylibs instead of building Debug ones.
#
# Everything it changes is scoped to that simulator and undone at the end.
# Integration state lives in a temporary directory, not in Voly's own, so a
# running Voly.app doesn't interfere and isn't interfered with — but don't
# point this at a simulator Voly currently has integration enabled for.

set -euo pipefail

UDID="${1:?usage: scripts/integration-test.sh <booted-simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
DERIVED="${VOLY_TEST_DERIVED_DATA:-$WORK/DerivedData}"
SUPPORT="$WORK/support"
BUNDLE=com.latifatci.VolySampleApp
PRODUCTS="$DERIVED/Build/Products/Debug-iphonesimulator"
RUNTIME="${VOLY_TEST_RUNTIME_DIR:-$PRODUCTS}"
VOLYCTL="$ROOT/Packages/VolyCore/.build/debug/volyctl"
FAILURES=0

ctl() { "$VOLYCTL" "$@" --support-dir "$SUPPORT"; }
send() { "$VOLYCTL" send "$UDID" "$BUNDLE" "$1" "${@:2}" 2>&1 || true; }

check() {   # check "<description>" <command…>  — passes when the command succeeds
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok    $name"; else echo "  FAIL  $name"; FAILURES=$((FAILURES + 1)); fi
}
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

launch() {  # launch [simctl flags…] ; environment comes from SIMCTL_CHILD_* of the caller
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl launch "$@" "$UDID" "$BUNDLE" | awk '{print $2}'
}
insert_libraries() { ps eww -p "$1" -o command= | tr ' ' '\n' | grep '^DYLD_INSERT_LIBRARIES=' || true; }

cleanup() {
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    ctl integration disable "$UDID" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== build"
build() {   # quiet unless it fails
    if ! "$@" >"$WORK/build.log" 2>&1; then cat "$WORK/build.log"; exit 1; fi
}
(cd "$ROOT/Packages/VolyCore" && build swift build --product volyctl)
if [ -z "${VOLY_TEST_RUNTIME_DIR:-}" ]; then
    for SCHEME in VolyAgentDylib VolyLaunchBridge; do
        build xcodebuild -project "$ROOT/Voly.xcodeproj" -scheme "$SCHEME" -configuration Debug \
            -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" build
    done
else
    echo "   using prebuilt dylibs from $RUNTIME"
fi
build xcodebuild -project "$ROOT/Voly.xcodeproj" -scheme SampleApp -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID,arch=$(uname -m)" -derivedDataPath "$DERIVED" build
xcrun simctl install "$UDID" "$PRODUCTS/SampleApp.app"

echo "== integration off: launches are stock"
PID=$(launch); sleep 2
check "no insert libraries without integration" lacks "$(insert_libraries "$PID")" "VolyAgent"

echo "== enable"
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null; sleep 1
SETTINGS_BEFORE=$(xcrun simctl spawn "$UDID" launchctl list | grep 'com.apple.Preferences' | awk '{print $1}')
STATE=$(ctl integration enable "$UDID" --agent "$RUNTIME/VolyAgent.dylib" --bridge "$RUNTIME/VolyLaunchBridge.dylib")
check "bridge reports active" contains "$STATE" "active("
SETTINGS_AFTER=$(xcrun simctl spawn "$UDID" launchctl list | grep 'com.apple.Preferences' | awk '{print $1}')
check "an app that was already running was not restarted" test -n "$SETTINGS_BEFORE" -a "$SETTINGS_BEFORE" = "$SETTINGS_AFTER"

echo "== injection preserves the launch environment"
export SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/usr/lib/libMainThreadChecker.dylib
export SIMCTL_CHILD_VOLY_SAMPLE_ROUTE=localize,detail
PID=$(launch); sleep 4
LIBS=$(insert_libraries "$PID")
check "existing insert library kept" contains "$LIBS" "libMainThreadChecker.dylib:"
check "agent appended after it" contains "$LIBS" "/VolyAgent.dylib"
check "agent not inserted twice" test "$(grep -o 'VolyAgent.dylib' <<<"$LIBS" | wc -l | tr -d ' ')" = 1
check "agent listens on loopback only" bash -c "lsof -nP -iTCP -sTCP:LISTEN -a -p $PID | grep -q '127.0.0.1:'"

echo "== authentication"
check "command without handshake is refused" contains "$(send '{"getHierarchy":{}}' --no-handshake)" "unauthorized"
check "handshake with a wrong token is refused" contains "$(send '{"ping":{}}' --wrong-token)" "handshake refused"
check "handshake with the port-file token works" contains "$(send '{"ping":{}}')" "pong"
HANDSHAKE=$("$VOLYCTL" handshake "$UDID" "$BUNDLE")
check "handshake names this process" contains "$HANDSHAKE" "\"pid\" : $PID"
check "handshake names this simulator" contains "$HANDSHAKE" "$UDID"

echo "== debugger-style launch (suspended until a debugger attaches)"
PID=$(launch --wait-for-debugger)
xcrun lldb --no-lldbinit -p "$PID" -o "script lldb.debugger.SetAsync(True)" -o "process continue" \
    -o "script import time; time.sleep(24)" \
    -o "image list -b VolyAgent.dylib" -o "process detach" -o "quit" >"$WORK/lldb.log" 2>&1 &
# (No "process interrupt" before detaching: if the detach wins the race, the
# pending SIGSTOP lands on a process nobody is debugging and freezes it.)
# Attaching and launching take a variable few seconds; wait for the agent
# rather than for a fixed time. The debugger stays attached well past this.
for _ in $(seq 1 18); do
    if contains "$(send '{"ping":{}}')" "pong"; then break; fi
    sleep 1
done
check "agent is up while the debugger is attached" contains "$(send '{"ping":{}}')" "pong"
check "inspection works under the debugger" contains "$(send '{"navigationState":{}}')" "LocalizationDetailVC"
check "same process, not relaunched" kill -0 "$PID"
wait
check "debugger saw the agent image and detached cleanly" bash -c "grep -q 'VolyAgent.dylib' '$WORK/lldb.log' && grep -q 'detached' '$WORK/lldb.log'"

echo "== localization"
STATE=$(send '{"localizationState":{}}')
check "languages discovered" contains "$STATE" '"code" : "ar"'
check "no hooks before the first override" lacks "$STATE" "localizedStringForKey"
APPLIED=$(send '{"setLocalizationOverride":{"_0":{"language":"ar","layoutDirectionMode":"followLanguage","refreshUI":true}}}')
check "override active" contains "$APPLIED" '"activeOverride" : "ar"'
check "layout mirrored for a right-to-left language" contains "$APPLIED" '"isLayoutRightToLeft" : true'
check "visible text was refreshed" bash -c "grep -Eq '\"updated\" : [1-9]' <<<'$APPLIED'"
LTR=$(send '{"setLocalizationOverride":{"_0":{"language":"ar","layoutDirectionMode":"leftToRight","refreshUI":true}}}')
check "language and layout direction are independent" contains "$LTR" '"isLayoutRightToLeft" : false'
check "unknown language is rejected" contains "$(send '{"setLocalizationOverride":{"_0":{"language":"xx","layoutDirectionMode":"system","refreshUI":false}}}')" "invalidCommand"
RESET=$(send '{"setLocalizationOverride":{"_0":{"language":null,"layoutDirectionMode":"system","refreshUI":true}}}')
check "reset clears the override" lacks "$RESET" "activeOverride"

echo "== navigation"
POP=$(send '{"navigate":{"_0":"pop"}}')
check "pop performed on a two-screen stack" contains "$POP" '"performed" : true'
check "a second pop during the transition is refused" contains "$(send '{"navigate":{"_0":"pop"}}')" '"performed" : false'
sleep 1.5
check "pop at the root is refused with a reason" contains "$(send '{"navigate":{"_0":"pop"}}')" "Already at the root screen."
check "dismiss with nothing presented is refused" contains "$(send '{"navigate":{"_0":"dismiss"}}')" "Nothing is presented."
export SIMCTL_CHILD_VOLY_SAMPLE_ROUTE=localize,detail,sheet-detail
PID=$(launch); sleep 4
check "pop to root works inside a presented stack" contains "$(send '{"navigate":{"_0":"popToRoot"}}')" '"performed" : true'
sleep 1.5
check "dismiss removes the sheet" contains "$(send '{"navigate":{"_0":"dismiss"}}')" '"performed" : true'
sleep 1.5
check "the stack under the sheet is intact" contains "$(send '{"navigationState":{}}')" '"navigationStackDepth" : 2'

echo "== screenshots"
SHOT=$("$VOLYCTL" screenshot "$UDID" "$BUNDLE" app "$WORK/app.png")
check "app capture at native pixel size" bash -c "grep -Eq '\"pixelWidth\":[0-9]{4}' <<<'$SHOT' && grep -q '\"scale\":[23]' <<<'$SHOT'"
check "app capture is a PNG" bash -c "file '$WORK/app.png' | grep -q 'PNG image data'"
check "single-view capture" bash -c "'$VOLYCTL' screenshot '$UDID' '$BUNDLE' view-class:UILabel '$WORK/view.png' | grep -q pixelWidth"
check "full-display capture through simctl" bash -c "'$VOLYCTL' sim-screenshot '$UDID' '$BUNDLE' '$WORK/sim.png' | grep -q portrait"

echo "== source lookup"
SOURCE=$("$VOLYCTL" source "$UDID" "$BUNDLE" UILabel)
check "a system view resolves to its app-defined owner" contains "$SOURCE" "candidate viewController SampleApp.LocalizationDetailVC"
check "debug info gives file and declaration line" bash -c "grep -Eq 'LocalizationDemoVC.swift:[0-9]+ \[debugInfo declaration\] LocalizationDetailVC' <<<'$SOURCE'"

echo "== policy"
ctl integration enable "$UDID" --agent "$RUNTIME/VolyAgent.dylib" --bridge "$RUNTIME/VolyLaunchBridge.dylib" --exclude "$BUNDLE" >/dev/null
PID=$(launch); sleep 2
check "an excluded app launches without the agent" lacks "$(insert_libraries "$PID")" "VolyAgent"
check "updating the policy did not restart the launch service" contains "$(ctl integration status "$UDID")" "active("

echo "== disable"
ctl integration disable "$UDID" >/dev/null
check "bridge unloaded" contains "$(ctl integration status "$UDID")" "inactive"
check "no integration files left" bash -c "[ ! -e '$SUPPORT/Simulators/$UDID' ]"
unset SIMCTL_CHILD_DYLD_INSERT_LIBRARIES
PID=$(launch); sleep 2
check "launches are stock again" lacks "$(insert_libraries "$PID")" "VolyAgent"

echo
if [ "$FAILURES" -eq 0 ]; then echo "All checks passed."; else echo "$FAILURES check(s) failed."; exit 1; fi
