#!/bin/bash
# End-to-end check of Voly's MCP server, the way an AI agent uses it:
#
#   MCP client (stdio) -> `Voly --mcp` helper -> socket -> a running Voly.app
#   -> its inspector session -> the agent inside SampleApp in a simulator.
#
# Usage: scripts/mcp-test.sh <booted-simulator-udid>
#
# It builds a Debug Voly.app and SampleApp, lets the helper start that Voly
# (confined to the given simulator, with its state in a temporary directory),
# and talks to it over MCP. Other booted simulators are left alone, and nothing is written to
# Voly's own support directory or preferences. Only one Voly can run at a
# time, so quit yours first; don't point this at a simulator you are using.

set -euo pipefail

UDID="${1:?usage: scripts/mcp-test.sh <booted-simulator-udid>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
DERIVED="${VOLY_TEST_DERIVED_DATA:-$WORK/DerivedData}"
# Short on purpose: a Unix socket path has to fit in about 100 characters.
SUPPORT="$WORK/s"
BUNDLE=com.latifatci.VolySampleApp
VOLY="$DERIVED/Build/Products/Debug/Voly.app/Contents/MacOS/Voly"
VOLYCTL="$ROOT/Packages/VolyCore/.build/debug/volyctl"
VOLY_PID=""

# By executable, not by command line: the helper and the app are the same
# binary, and a shell that merely mentions the path must not count.
voly_running() { ps -axo comm= | grep -q "Voly.app/Contents/MacOS/Voly$"; }
voly_app_pid() { ps -axo pid=,args= | grep -E "Voly\.app/Contents/MacOS/Voly$" | awk '{print $1}' | head -1; }

if voly_running; then
    echo "A Voly is already running. Quit it first: only one can run at a time." >&2
    exit 2
fi

cleanup() {
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    if [ -n "$VOLY_PID" ] && kill -0 "$VOLY_PID" 2>/dev/null; then
        kill -TERM "$VOLY_PID" 2>/dev/null || true      # quits cleanly: unloads its launch bridge
        for _ in $(seq 1 40); do kill -0 "$VOLY_PID" 2>/dev/null || break; sleep 0.25; done
        kill -KILL "$VOLY_PID" 2>/dev/null || true
    fi
    # In case Voly didn't get to unload its launch bridge itself.
    "$VOLYCTL" integration disable "$UDID" --support-dir "$SUPPORT" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== build"
build() {   # quiet unless it fails
    if ! "$@" >"$WORK/build.log" 2>&1; then cat "$WORK/build.log"; exit 1; fi
}
(cd "$ROOT/Packages/VolyCore" && build swift build --product volyctl)
build xcodebuild -project "$ROOT/Voly.xcodeproj" -scheme Voly -configuration Debug \
    -derivedDataPath "$DERIVED" build
build xcodebuild -project "$ROOT/Voly.xcodeproj" -scheme SampleApp -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID,arch=$(uname -m)" -derivedDataPath "$DERIVED" build
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/SampleApp.app"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true

echo "== the helper answers without Voly, and does not start it when told not to"
export VOLY_SUPPORT_DIRECTORY="$SUPPORT"
export VOLY_MCP_NO_LAUNCH=1
OFFLINE=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}' \
    | "$VOLY" --mcp)
FAILURES=0
check() {   # check "<description>" <command…>
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok    $name"; else echo "  FAIL  $name"; FAILURES=$((FAILURES + 1)); fi
}
contains() { [[ "$1" == *"$2"* ]]; }
check "initialize answered" contains "$OFFLINE" '"protocolVersion":"2025-06-18"'
check "tools listed" contains "$OFFLINE" '"name":"get_screen"'
check "a tool call says Voly isn't running" contains "$OFFLINE" "Voly isn't running"
check "the helper did not start Voly" test -z "$(voly_app_pid)"

echo "== the first tool call starts Voly (confined to this simulator)"
unset VOLY_MCP_NO_LAUNCH
export VOLY_SCRIPTED_RUN=1 VOLY_SCRIPTED_SIMULATORS="$UDID"     # the helper passes these on
STARTED=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}' \
    | "$VOLY" --mcp)
VOLY_PID=$(voly_app_pid)
check "Voly is running now" test -n "$VOLY_PID"
check "and answered the call that started it" contains "$STARTED" "Booted simulators"
contains "$STARTED" "Booted simulators" || echo "        $STARTED"
check "Voly opened its socket" test -S "$SUPPORT/mcp.sock"
check "the socket is private to the user" test "$(stat -f '%Lp' "$SUPPORT/mcp.sock")" = 600

echo "== drive it over MCP"
set +e
python3 - "$UDID" "$BUNDLE" "$WORK" "$VOLY" --mcp <<'PYTHON'
import base64, json, os, re, struct, subprocess, sys, time

udid, bundle, work = sys.argv[1:4]
server = subprocess.Popen(sys.argv[4:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
failures = 0
next_id = 0

def rpc(method, params=None):
    global next_id
    next_id += 1
    message = {"jsonrpc": "2.0", "id": next_id, "method": method}
    if params is not None:
        message["params"] = params
    server.stdin.write((json.dumps(message) + "\n").encode())
    server.stdin.flush()
    reply = json.loads(server.stdout.readline())
    assert reply["id"] == next_id, reply
    return reply

class Result:
    def __init__(self, reply):
        result = reply.get("result", {})
        self.is_error = "error" in reply or result.get("isError", False)
        parts = result.get("content", [])
        self.text = "\n".join(p["text"] for p in parts if p["type"] == "text") or json.dumps(reply.get("error", ""))
        self.images = [base64.b64decode(p["data"]) for p in parts if p["type"] == "image"]

def call(name, **arguments):
    return Result(rpc("tools/call", {"name": name, "arguments": arguments}))

def check(name, passed, detail=""):
    global failures
    print(f"  {'ok   ' if passed else 'FAIL '} {name}")
    if not passed:
        failures += 1
        if detail:
            print("        " + detail.replace("\n", "\n        ")[:1500])

def wait_for(condition, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(1)
    return condition()

def launch(route):
    subprocess.run(["xcrun", "simctl", "terminate", udid, bundle], capture_output=True)
    subprocess.run(["xcrun", "simctl", "launch", udid, bundle], capture_output=True, check=True,
                   env={**os.environ, "SIMCTL_CHILD_VOLY_SAMPLE_ROUTE": route})

def view_id(text, pattern):
    match = re.search(pattern, text)
    return int(match.group(1)) if match else None

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "mcp-test", "version": "1"}})["result"]
check("initialize: tools capability and instructions",
      "tools" in init["capabilities"] and "get_screen" in init.get("instructions", ""), json.dumps(init)[:400])
tools = rpc("tools/list")["result"]["tools"]
names = {tool["name"] for tool in tools}
check("tools/list has the reading and the changing tools",
      {"list_apps", "get_screen", "get_view", "find_views", "get_selection", "screenshot",
       "set_property", "set_constraint", "navigate", "set_language"} <= names, str(sorted(names)))
check("every tool has a description and an object schema",
      all(tool["description"] and tool["inputSchema"]["type"] == "object" for tool in tools))

# Integration first, so the app we launch next gets the agent.
ready = wait_for(lambda: (lambda r: r if "apps launched here are inspectable" in r.text else None)(call("list_apps")), 60)
check("list_apps: the simulator is integrated", bool(ready), call("list_apps").text)
overview = call("list_apps").text
simulators = [line for line in overview.splitlines() if line.startswith("- ") and "bundle=" not in line]
check("list_apps: this Voly sees only the simulator it was confined to",
      len(simulators) == 1 and udid in simulators[0], overview)

launch("localize")
listed = wait_for(lambda: (lambda r: r if bundle in r.text and "Inspectable apps:" in r.text else None)(call("list_apps")), 40)
check("list_apps: the launched app is inspectable", bool(listed), call("list_apps").text)

screen = call("get_screen")
check("get_screen: header names app, size and top view controller",
      not screen.is_error and "SampleApp" in screen.text and "pt @" in screen.text
      and "Top view controller: LocalizationDemoVC" in screen.text, screen.text[:600])
check("get_screen: label with text, font, color, identifier",
      re.search(r'UILabel #\d+ [\d.]+,[\d.]+ [\d.]+×[\d.]+ "Welcome to Voly" font=System \w+ 22 color=#000000 id=loc\.greeting', screen.text) is not None, screen.text)
check("get_screen: placeholder, control value, stack settings",
      'placeholder="Your name"' in screen.text and "value=selected: " in screen.text
      and "stack(vertical spacing=14" in screen.text, screen.text)
# White on the system blue (whose exact value differs between iOS versions), not the tint color as text.
check("get_screen: filled button shows its real colors",
      re.search(r'UIButton #\d+ .*"Show Details".* color=#FFFFFF bg=#00[0-9A-F]{2}FF ', screen.text) is not None, screen.text)
check("get_screen: view controllers are named", "vc=LocalizationDemoVC" in screen.text and "vc=UINavigationController" in screen.text)
check("get_screen: SwiftUI text appears as an accessibility element", '~ "Hello from SwiftUI"' in screen.text, screen.text)
check("get_screen: wrapper chains are folded", " › " in screen.text)
check("get_screen: fits a model's context", len(screen.text) < 40_000, str(len(screen.text)))

label = view_id(screen.text, r'UILabel #(\d+) [^\n]*id=loc\.subtitle')
stack = view_id(screen.text, r'UIStackView #(\d+) [^\n]*stack\(vertical')
button = view_id(screen.text, r'UIButton #(\d+) [^\n]*id=loc\.details')
check("ids for the label, stack and button were found", None not in (label, stack, button), f"{label} {stack} {button}")

subtree = call("get_screen", root=stack, max_depth=1)
check("get_screen root=: only that subtree, with where it sits",
      subtree.text.count("UILabel #") == 5 and "Inside:" in subtree.text and "UITabBarButton" not in subtree.text, subtree.text)

view = call("get_view", view=label)
check("get_view: layout inputs", "Layout: Auto Layout" in view.text and "hugging H" in view.text, view.text)
check("get_view: constraints as phrases with ids",
      re.search(r"- #\d+ Top to UILabel\.bottom \+ 14", view.text) is not None, view.text)
check("get_view: properties", "numberOfLines=" in view.text and "alpha=1" in view.text, view.text)
check("get_view: source file and line of the owning view controller",
      re.search(r"LocalizationDemoVC\.swift:\d+", view.text) is not None, view.text)

found = call("find_views", text="swiftui")
check("find_views text: finds SwiftUI content", "Hello from SwiftUI" in found.text, found.text)
found = call("find_views", accessibility_id="loc.details")
check("find_views accessibility_id", f"UIButton #{button}" in found.text, found.text)
x, y, width, height = map(float, re.search(rf"UIButton #{button} ([\d.]+),([\d.]+) ([\d.]+)×([\d.]+)", screen.text).groups())
found = call("find_views", x=x + width / 2, y=y + height / 2)
check("find_views at a point: innermost first", found.text.splitlines()[1].startswith(f"UIButton #{button}"), found.text)

def png_size(data):
    return struct.unpack(">II", data[16:24]) if data[:8] == b"\x89PNG\r\n\x1a\n" else None

shot = call("screenshot")
check("screenshot: a PNG no larger than asked, with the scale in the caption",
      len(shot.images) == 1 and png_size(shot.images[0]) is not None and max(png_size(shot.images[0])) <= 1568
      and "1 pt = " in shot.text, shot.text)
shot = call("screenshot", view=button, max_dimension=300)
check("screenshot of one view", len(shot.images) == 1 and max(png_size(shot.images[0]) or (9999,)) <= 300, shot.text)
shot = call("screenshot", target="simulator", max_dimension=800)
check("screenshot of the whole simulator display", len(shot.images) == 1 and max(png_size(shot.images[0]) or (9999,)) <= 800, shot.text)

selected = call("select_view", view=button)
check("select_view", not selected.is_error and "Show Details" in selected.text, selected.text)
selection = wait_for(lambda: (lambda r: r if f"UIButton #{button}" in r.text else None)(call("get_selection", source=False)), 5)
check("get_selection: returns what is selected in Voly", bool(selection), call("get_selection", source=False).text)

changed = call("set_property", view=label, property="backgroundColor", value="#FFCC00")
check("set_property: applied", not changed.is_error, changed.text)
check("set_property: visible in the next read", "bg=#FFCC00" in call("get_screen", root=label).text)
refused = call("set_property", view=label, property="alpha", value="opaque")
check("set_property: a wrong value type is refused with a reason", refused.is_error and "number" in refused.text, refused.text)

constraint = view_id(view.text, r"- #(\d+) Top to UILabel\.bottom \+ 14")
before = call("get_screen", root=label).text
moved = call("set_constraint", view=label, constraint=constraint, constant=40)
after = call("get_screen", root=label).text
frame = lambda text: re.search(rf"UILabel #{label} ([\d.]+),([\d.]+)", text).groups()
check("set_constraint: the view moved by the new constant",
      not moved.is_error and abs(float(frame(after)[1]) - float(frame(before)[1]) - 26) < 1, moved.text + "\n" + before + "\n" + after)

state = call("get_app_state")
check("get_app_state: navigation and languages",
      "Top view controller: LocalizationDemoVC" in state.text and "fr (French)" in state.text, state.text)
french = call("set_language", language="fr")
check("set_language: switched", not french.is_error and "fr (set through Voly)" in french.text, french.text)
check("set_language: on-screen text follows", "Bienvenue" in call("find_views", accessibility_id="loc.greeting").text)
call("set_language", language="system")

popped = call("navigate", action="pop")
check("navigate: refuses with the reason when there is nothing to pop", popped.is_error and "root" in popped.text, popped.text)

call("set_user_default", key="voly.mcp.test", value=42)
check("user defaults: written and read back", "voly.mcp.test (int) = 42" in call("get_user_defaults", contains="voly.mcp").text)
call("set_user_default", key="voly.mcp.test", value=None)

launch("form")
password = wait_for(lambda: view_id(call("find_views", accessibility_id="form_password").text, r"UITextField #(\d+)"), 30)
check("the password field of the form screen is found", password is not None)
typed = call("set_property", view=password, property="text", value="hunter2-secret")
check("text can be put into it", not typed.is_error, typed.text)
leaks = [call("get_screen").text, call("get_view", view=password, source=False).text,
         call("find_views", accessibility_id="form_password").text, call("find_views", text="hunter2").text]
check("what is typed into a secure field never reaches the agent",
      all("hunter2" not in text for text in leaks) and "(secure text, 14 characters)" in leaks[0] and "[secure]" in leaks[0],
      "\n".join(text for text in leaks if "hunter2" in text) or leaks[0])

stale = call("get_view", view=987654)
check("an unknown view id is an error that says what to do", stale.is_error and "get_screen" in stale.text, stale.text)
unknown = rpc("tools/call", {"name": "no_such_tool", "arguments": {}})
check("an unknown tool is a protocol error", unknown.get("error", {}).get("code") == -32602, json.dumps(unknown))

relaunched = call("relaunch_app", bundle_id=bundle)
check("relaunch_app: the app comes back inspectable", not relaunched.is_error and "Now inspectable" in relaunched.text, relaunched.text)
fresh = wait_for(lambda: (lambda r: r if "SampleApp" in r.text and not r.is_error else None)(call("get_screen", max_depth=2)), 40)
check("get_screen works on the relaunched process", bool(fresh), call("get_screen", max_depth=2).text + "\n" + call("list_apps").text)

server.stdin.close()
check("the helper exits when the client closes its stream", server.wait(timeout=15) == 0)
sys.exit(1 if failures else 0)
PYTHON
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))
set -e

echo "== quit"
kill -TERM "$VOLY_PID"
for _ in $(seq 1 60); do kill -0 "$VOLY_PID" 2>/dev/null || break; sleep 0.25; done
check "Voly quit" bash -c "! kill -0 $VOLY_PID"
check "the socket is gone" test ! -e "$SUPPORT/mcp.sock"
check "its launch bridge was unloaded from the simulator" contains \
    "$("$VOLYCTL" integration status "$UDID" --support-dir "$SUPPORT")" "inactive"
VOLY_PID=""

echo
if [ "$FAILURES" -eq 0 ]; then echo "All checks passed."; else echo "$FAILURES check(s) failed."; exit 1; fi
