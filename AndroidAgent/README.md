# Voly's Android agent

What Voly loads into a running Android app to inspect it. The counterpart
of `Packages/VolyCore/Sources/VolyAgent` (the iOS agent), speaking the same
wire protocol, so the Mac side talks to both the same way.

```
src/main/java/dev/voly/agent/   the agent (Java, platform APIs only, no dependencies)
src/main/cpp/                   the JVMTI library that loads it
build.sh                        builds both into ../Voly/AndroidAgentPayload
```

## How it gets into an app

```
adb push            voly-agent.dex, libvolyagent-<abi>.so → /data/local/tmp/voly-<version>/
run-as <package>    copies them into the app's code_cache/      (debuggable apps only)
cmd activity attach-agent <pid> …/libvolyagent-<abi>.so=dex=…,socket=…,token=…,info=…
adb forward         tcp:<port on the Mac> → localabstract:<socket>
```

`attach-agent` is the mechanism Android Studio's Layout Inspector uses. The
library is loaded into the running process — the app is not restarted and a
debugger stays attached — and calls `Bootstrap.start`, which opens a
WebSocket server on an abstract Unix socket. Every command is refused until
a handshake carries the token Voly generated for that attach.

Requirements this puts on the app: Android 8 (API 26) or later, and a
debuggable build. Nothing is added to the app's view hierarchy: the
highlight is drawn through each window's `ViewOverlay`, and pick mode wraps
each window's `Window.Callback` while it is on.

One thing does change in the process: the agent reads a few platform
internals (the list of windows and activities, a drawable's stroke), so the
loader lifts the hidden-API filter for that process when it attaches. An
app that itself reflects on hidden APIs can therefore behave differently
with the agent loaded than without. It lasts until the app exits.

## Building

```sh
ANDROID_HOME=~/Library/Android/sdk AndroidAgent/build.sh
```

Needs a JDK (the one inside Android Studio is used when there is no other)
and, from the Android SDK, a platform, build-tools and the NDK
(`sdkmanager "platforms;android-35" "build-tools;35.0.0" "ndk;27.2.12479018"`).
The NDK only builds the small loader in `src/main/cpp`: after a change to the
Java alone, `AndroidAgent/build.sh --java-only` rebuilds the agent and keeps
the loaders that are checked in.
The output in `Voly/AndroidAgentPayload` is checked in, so building Voly.app
itself needs none of this; rebuild and commit it after changing the agent.
`voly-agent.version` is a hash of the built files and names the copy on a
device, so a new build is picked up without cleaning anything.

## How Android maps onto the protocol

| Host concept | On Android |
| --- | --- |
| Points | dp, measured from the display's top-left corner (every window shares it) |
| Accessibility identifier | the entry name of the view's `android:id` |
| View controller | the activity a window belongs to, the fragment a view is the root of |
| `view` / `layer` properties | alpha, visibility, background and tint colors; corner radius, border, elevation |
| Custom properties | text, text size and color, padding, margins, `layout_width`/`height`, weight, bias, …, plus getter/setter pairs of the app's own view classes |
| Constraints | fixed sizes, non-zero margins and every ConstraintLayout connection, with the margin as the constant |
| A view (`ViewNode`) | a view, or a node of Jetpack Compose content inside an `AndroidComposeView` |
| SwiftUI accessibility elements | Jetpack Compose semantics nodes: text, role, state, test tag, bounds |
| UserDefaults | SharedPreferences; a suite is a preferences file |
| Language override | per-app language (`LocaleManager`) on Android 13+, a configuration override before |
| Dismiss / pop / pop to root | close a dialog, sheet or popup / Back / empty the back stacks |
| Source lookup | class names and the view's id, resolved on the Mac by searching the project |

## Jetpack Compose

A Compose screen is one view. Its content is layout nodes, which
`ViewGroup.getChildAt` never returns, so the view tree would end at
`AndroidComposeView`. `ComposeTree` reads them and the rest of the agent
treats them like views: `Snapshots` adds them to the tree, `Ui.hitTest`
finds the node under a point, and everything that only needs to know where
a thing is (`Overlay`, `Screenshots`, measuring) takes a `Target`, which is
a view or a node.

Compose is part of the app, so all of it is reflection, and nearly all of
it on public API: a node is a `LayoutInfo`, with its coordinates, modifiers
and semantics. The exception is a node's children (`LayoutNode.zSortedChildren`,
or the `internal` `children`, whose compiled name changed from
`getChildren$ui_release` to `getChildren$ui` in Compose 1.10). When neither
is there, the tree is built from the semantics tree instead: fewer nodes,
the same frames, the same ids.

| | |
| --- | --- |
| Identity | `ComposeNode`: the host view and Compose's own id for the node (`semanticsId`). Stable from one snapshot to the next. |
| Name | The semantics role, `Text` for text, else the class of the measure policy: `RowMeasurePolicy` is a `Row`. Not the composable function: that is not in the node. |
| Frame | The box of the outermost modifier that paints or takes taps (background, border, clip, clickable), else the node's content box. Padding outside that is spacing; padding inside it is part of the node. Unclipped. |
| Properties | Semantics, text style (from the text modifier's `TextStyle`), and each modifier with what it tells Compose's own inspector, or else its fields. Read-only. |

`scripts/android-agent-test.sh` runs `tests/` — the agent against a real
Compose on the JVM (Robolectric), for whichever releases of Compose it is
given. CI runs it for four of them. Run it with a new release before
relying on that release.
