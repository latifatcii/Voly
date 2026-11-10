# Voly

A live UIKit inspector for the iOS Simulator. Voly is a macOS menu-bar app that docks next to the Simulator and lets you inspect and edit the app that is running in it — without adding anything to the app, and without disturbing your Xcode debug session.

| View tree | Layout |
| --- | --- |
| ![The inspector's view tree with a selected label](assets/inspector-tree.png) | ![Frame, bounds and constraints of the selected view](assets/inspector-layout.png) |

- Inspect the full view hierarchy and pick views by clicking them in the simulator
- Edit `UIView` / `CALayer` properties and Auto Layout constraints live
- Measure the distance between two views
- Jump to the exact source file and line in Xcode
- Switch the app's language live, with independent layout direction
- Capture the simulator screen, the app's content, or a single view
- Dismiss / pop / pop to root from the inspector
- Inspect and edit `UserDefaults`, and fire deep links

## Install

1. Download `Voly-<version>.dmg` from [Releases](https://github.com/latifatcii/Voly/releases).
2. Open it and drag **Voly** into **Applications**.
3. Open Voly. The build is not notarized, so macOS blocks the first launch: right-click the app and choose **Open**, or allow it under **System Settings → Privacy & Security**. From a terminal you can clear the flag instead:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Voly.app
   ```

Requirements: macOS 14 or later, and Xcode with at least one iOS Simulator runtime. Runtime integration is verified on Xcode 26.2 with the iOS 18.3 and 26.2 simulator runtimes; on a runtime it can't work with, Voly says so instead of guessing.

## Using it

1. Launch Voly. It lives in the menu bar. Each booted simulator gets runtime integration within a few seconds.
2. Run your app as usual — Xcode ⌘R, the home screen, or `simctl launch`. It comes up inspectable, with the debugger still attached.
3. Press **⌘E** while the Simulator is frontmost (or **⌃⌥⌘V** from anywhere) to show Voly. It docks next to the simulator window you last focused and opens in pick mode: click a view in any simulator to select it. Press Esc to hand taps back to the app.

Apps that were already running before Voly started are listed as not instrumented; they become inspectable the next time they launch. Voly never restarts an app by itself — the **Relaunch…** button next to such an app does it after asking.

| Shortcut | Action |
| --- | --- |
| ⌘E (Simulator frontmost) | Show / hide Voly |
| ⌃⌥⌘V | Show / hide Voly from anywhere |
| ⌃⌥⌘M | Pick mode on / off |
| ⌃⌥⌘J | Jump to Source for the selected view |
| Esc | Leave pick mode |

Voly asks for Accessibility permission only for live hover measurement while picking. Everything else, including docking and selecting by click, works without it.

### Choosing simulators and apps

Integration applies to every booted simulator by default. Switch a simulator off in the Simulators tab or under menu bar → **Runtime Integration**, or uncheck **All simulators** to pick them by hand. Right-click an app in the list to exclude it, or to instrument only selected apps. Apple's own apps are left alone.

An app launched with `VOLY_DISABLE=1` in its environment is never instrumented.

## How it works

```
Voly.app ──simctl spawn <udid> launchctl debug … ─▶ simulator's runningboardd
                                                     └─ VolyLaunchBridge.dylib
Xcode / SpringBoard / simctl ── launch request ─────▶ bridge appends VolyAgent.dylib
                                                       to DYLD_INSERT_LIBRARIES
app starts with the agent ◀── loopback WebSocket + token ──▶ Voly.app
```

- A small bridge is loaded into the simulator's `runningboardd`, the process every app launch passes through. For eligible apps it appends Voly's agent to the launch's `DYLD_INSERT_LIBRARIES`, keeping whatever was already there — including the libraries Xcode inserts for debugging.
- The agent listens on `127.0.0.1` only and requires a per-process token before accepting any command.
- Jump to Source resolves addresses through LLDB's line tables on the binary on disk. It never attaches to your app.

What Voly changes, and how it is undone:

| Change | Removed by |
| --- | --- |
| A one-shot `launchctl debug` environment for the simulator's `runningboardd` | automatically; it is consumed by the restart Voly triggers |
| The bridge loaded in that `runningboardd` | switching the simulator off, quitting Voly, or shutting the simulator down |
| `~/Library/Developer/Voly/` (config, status, copies of the two dylibs) | switching integration off; pruned as simulators shut down |

Nothing is written into the simulator runtime, Xcode, or macOS settings, and physical devices are never touched. Restarting the simulator's `runningboardd` does not terminate running apps.

## Limitations

- **Simulators only.** The SDK (below) can run on a device and advertise itself on the local network, but that path is not exercised.
- **UIKit.** SwiftUI views appear as the UIKit views that host them.
- **Language refresh is exact, not exhaustive.** Text already on screen is rewritten only when it is exactly a value from one of the app's `.strings` tables. Formatted strings, plurals, hard-coded text and SwiftUI `Text` keep their old language until their screen is rebuilt. Editable text is never touched.
- **Source lookup needs debug info** (a Debug build, or a dSYM LLDB can find). Without it you get a file-name match.
- **Private API.** The bridge relies on a private RunningBoard method. It checks for it on every load and refuses to hook otherwise, but a future iOS runtime can remove it.
- **One Voly at a time.** A second copy would manage the same simulators, so it says so and quits.

## Linking the SDK (optional)

Simulator apps don't need this. Link `VolyAgent` when you want to register custom properties, or to run the agent from inside your own build instead of having it loaded for you.

1. Add this repository as a Swift package and link the `VolyAgent` library into your app target.
2. At scene setup, wrap your root view controller:

   ```swift
   import VolyAgent

   func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
       VolyAgent.start()
       guard let windowScene = scene as? UIWindowScene else { return }
       let window = UIWindow(windowScene: windowScene)
       window.rootViewController = VolyAgent.wrap(original: YourRootVC())
       self.window = window
       window.makeKeyAndVisible()
   }
   ```

3. Add `NSBonjourServices = ["_voly-agent._tcp"]` and an `NSLocalNetworkUsageDescription` to your Info.plist.
4. Launch with `VOLY_AGENT_ENABLED=1` in the environment.

The SDK is inert unless the app is a Debug build, `VOLY_AGENT_ENABLED=1` (or `--voly-agent-enabled`) is set, and your code calls `VolyAgent.start()`. In Release builds it is a no-op. SDK agents advertise over Bonjour on the local network and are not token-protected.

Custom properties the Objective-C runtime can't see can be registered:

```swift
VolyAgent.register(BadgeView.self, property: "badgeText", type: .string,
    get: { .string($0.badgeText) },
    set: { view, value in
        if case .string(let s) = value { view.badgeText = s }
    })
```

## Building from source

```sh
# The macOS app; also builds and embeds the two simulator dylibs
xcodebuild -project Voly.xcodeproj -scheme Voly -destination 'platform=macOS' build

# Unit tests (host logic, protocol, localization support)
(cd Packages/VolyCore && swift test)

# End-to-end check against a booted simulator
scripts/integration-test.sh <booted-simulator-udid>

# A distributable DMG in build/dist
scripts/package-release.sh
```

```
Voly/                  macOS app (SwiftUI + AppKit)
Packages/VolyCore/     Swift package
  Sources/VolyAgent/     the in-app agent
  Sources/VolyHost/      simulator integration, discovery, source lookup
  Sources/VolyProtocol/  commands, responses, framing
  Sources/VolyModels/    shared model types
  Sources/volyctl/       command-line client over the same host code
LoaderShim/            starts the agent when it is loaded as a dylib
LaunchBridge/          the dylib loaded into the simulator's runningboardd
SampleApp/             a UIKit app to try Voly against
scripts/               integration test and release packaging
```

`volyctl` drives the same code as the app from a terminal; see the header of `Packages/VolyCore/Sources/volyctl/main.swift`. A Debug build can also render every inspector tab from fixture data to PNG files, without a simulator: `VOLY_UI_PREVIEW=/tmp/voly-ui Voly.app/Contents/MacOS/Voly`.
