#!/bin/bash
# Checks, in a real iOS Simulator, that editing text through Voly keeps the
# styling the app gave it: runs in a label, letter spacing, a blurred shadow,
# attributed button titles (with and without a configuration), an attributed
# placeholder, and the font of a text view that isn't selectable.
#
# Builds the simulator dylibs and SampleApp, opens the sample's styled-text
# screen (VOLY_SAMPLE_ROUTE=styled) and edits each text the way the
# inspector's property panel does, through `volyctl send`. The screen has a
# probe next to each text that reports its styling; the checks read those.
#
# Usage: scripts/text-style-test.sh <booted-simulator-udid>
#
# Set VOLY_TEST_RUNTIME_DIR to a directory holding VolyAgent.dylib and
# VolyLaunchBridge.dylib to test those instead of building Debug ones.
#
# Like scripts/integration-test.sh, everything it changes is scoped to that
# simulator and undone at the end, and its integration state lives in a
# temporary directory — but don't point it at a simulator Voly currently has
# integration enabled for.

set -euo pipefail

UDID="${1:?usage: scripts/text-style-test.sh <booted-simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
DERIVED="${VOLY_TEST_DERIVED_DATA:-$WORK/DerivedData}"
SUPPORT="$WORK/support"
BUNDLE=com.latifatci.VolySampleApp
PRODUCTS="$DERIVED/Build/Products/Debug-iphonesimulator"
RUNTIME="${VOLY_TEST_RUNTIME_DIR:-$PRODUCTS}"
VOLYCTL="$ROOT/Packages/VolyCore/.build/debug/volyctl"

ctl() { "$VOLYCTL" "$@" --support-dir "$SUPPORT"; }

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

echo "== launch the styled-text screen with the agent"
ctl integration enable "$UDID" --agent "$RUNTIME/VolyAgent.dylib" --bridge "$RUNTIME/VolyLaunchBridge.dylib" >/dev/null
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
SIMCTL_CHILD_VOLY_SAMPLE_ROUTE=styled xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
for _ in $(seq 1 20); do
    if "$VOLYCTL" send "$UDID" "$BUNDLE" '{"navigationState":{}}' 2>/dev/null | grep -q StyledTextDemoVC; then break; fi
    sleep 0.5
done

python3 - "$VOLYCTL" "$UDID" "$BUNDLE" <<'PYTHON'
import json, subprocess, sys

volyctl, udid, bundle = sys.argv[1:4]
failures = 0

def send(command):
    out = subprocess.run([volyctl, "send", udid, bundle, json.dumps(command)], capture_output=True, text=True)
    try:
        return json.loads(out.stdout)
    except ValueError:
        sys.exit(f"volyctl send failed: {out.stdout}{out.stderr}")

def walk(node, children):
    yield node
    for child in node.get(children) or []:
        yield from walk(child, children)

screen = send({"describeScreen": {"_0": {}}})["screenDescription"]["_0"]
ids = {}
for root in screen["roots"]:
    for node in walk(root, "children"):
        if node.get("accessibilityIdentifier"):
            ids[node["accessibilityIdentifier"]] = node["id"]

def string_property(view, name):
    bag = send({"getProperties": {"objectID": view}})["properties"]["_0"]
    for descriptor in bag["custom"]:
        if descriptor["name"] == name:
            return descriptor["currentValue"].get("string", {}).get("_0")
    return None

def report(name):
    return string_property(ids["probe." + name], "report")

def set_string(view, text, name="text"):
    reply = send({"setProperty": {"_0": {
        "objectID": view, "scope": "custom", "change": {"property": name, "value": {"string": {"_0": text}}},
    }}})
    if "error" in reply:
        print(f"        setting {name} of #{view} failed: {reply}")

def labels_of(button):
    """A button's own labels by the text they show, the way the inspector's tree lists them."""
    hierarchy = send({"getHierarchy": {}})["hierarchy"]["_0"]
    found = {}
    for scene in hierarchy["scenes"]:
        for window in scene["windowsInline"]:
            for node in walk(window, "childrenInline"):
                if node["id"] != button:
                    continue
                for label in walk(node, "childrenInline"):
                    if "Label" in label["className"]:
                        found[string_property(label["id"], "text")] = label["id"]
    return found

def check(what, name, expected):
    global failures
    actual = report(name)
    if actual == expected:
        print(f"  ok    {what}")
    else:
        failures += 1
        print(f"  FAIL  {what}\n        expected {expected}\n        got      {actual}")

print("== a label with several runs")
runs = ids["styled.runs"]
check("the screen starts as the sample styled it", "runs",
      "Total {17 k1.5 lh1.2}|due{17B k1.5 lh1.2 red}| today{17 k1.5 lh1.2}")
set_string(runs, "Total due now")
check("an edit in one run leaves the others alone", "runs",
      "Total {17 k1.5 lh1.2}|due{17B k1.5 lh1.2 red}| now{17 k1.5 lh1.2}")
set_string(runs, "Total paid now")
check("new characters take the styling of the ones they replace", "runs",
      "Total {17 k1.5 lh1.2}|paid{17B k1.5 lh1.2 red}| now{17 k1.5 lh1.2}")
set_string(runs, "")
check("clearing empties it", "runs", "empty")
set_string(runs, "Paid")
check("typing again brings back the styling it started with", "runs", "Paid{17 k1.5 lh1.2}")

print("== letter spacing and a blurred shadow")
set_string(ids["styled.spaced"], "ORDERS")
check("letter spacing survives an edit", "spaced", "ORDERS{13B k3}")
set_string(ids["styled.spaced"], "")
set_string(ids["styled.spaced"], "NEW")
check("and clearing and typing again", "spaced", "NEW{13B k3}")
set_string(ids["styled.glow"], "Glows")
check("a shadow only an attributed string can hold survives", "glow", "Glows{20 blur4}")

print("== a button with a configuration")
buy = ids["styled.buy"]
check("starts with a two-run title and a spaced subtitle", "buy",
      "title Buy {17}|Pro{17B} subtitle per month{11 k2}")
labels = labels_of(buy)
title, subtitle = labels.get("Buy Pro"), labels.get("per month")
if title is None or subtitle is None:
    failures += 1
    print(f"  FAIL  the button's title and subtitle labels are in the tree (found {sorted(map(str, labels))})")
else:
    set_string(title, "Get Pro")
    check("an edit in one run of the title leaves the other alone", "buy",
          "title Get {17}|Pro{17B} subtitle per month{11 k2}")
    set_string(subtitle, "per year")
    check("the subtitle keeps its letter spacing", "buy", "title Get {17}|Pro{17B} subtitle per year{11 k2}")
    set_string(title, "")
    set_string(subtitle, "each year")
    check("a cleared title stays cleared while the subtitle is edited", "buy",
          "title empty subtitle each year{11 k2}")
    set_string(title, "Buy")
    check("and comes back in the styling it started with", "buy", "title Buy{17} subtitle each year{11 k2}")
    set_string(title, "")
    set_string(ids["probe.buy"], "Next", name="appTitle")
    set_string(title, "Next!")
    check("a title the app set after it was cleared is left in the app's styling", "buy",
          "title Next!{} subtitle each year{11 k2}")

print("== a button without a configuration")
sign_in = ids["styled.signIn"]
label = labels_of(sign_in).get("Sign in")
if label is None:
    failures += 1
    print("  FAIL  the button's title label is in the tree")
else:
    set_string(label, "Sign up")
    check("an attributed title keeps its underline and spacing", "signIn", "Sign up{15 k1 ul}")
    set_string(label, "")
    set_string(label, "Go")
    check("and after clearing and typing again", "signIn", "Go{15 k1 ul}")
    set_string(label, "")
    set_string(ids["probe.signIn"], "Next", name="appTitle")
    set_string(label, "Next!")
    check("a title the app set after it was cleared is left in the app's styling", "signIn", "plain Next!")

print("== a text view that isn't selectable")
notes = ids["styled.notes"]
check("starts in the font the sample gave it", "notes", "font Georgia text Notes{18}")
set_string(notes, "Note")
check("an edit keeps the font", "notes", "font Georgia text Note{18}")
set_string(notes, "")
set_string(notes, "New")
check("and so does clearing and typing again", "notes", "font Georgia text New{18}")

print("== an attributed placeholder")
set_string(ids["styled.email"], "E-mail", name="placeholder")
check("keeps its color and letter spacing", "email", "E-mail{k2 purple}")

print()
print("FAILED: %d" % failures if failures else "all text styling checks passed")
sys.exit(1 if failures else 0)
PYTHON
