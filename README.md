# Voly

Live iOS inspector / editor — a macOS host that connects to a running UIKit app in the iOS Simulator (or on device) and lets a developer:

- inspect the full view hierarchy
- visually pick views
- edit UIView / CALayer properties live
- edit Auto Layout constraints
- inspect custom / @IBInspectable properties
- edit UserDefaults
- test deep links
- jump to the exact source file and line in Xcode
- switch the app's language live, with independent layout direction
- capture the simulator screen, the app's content, or a single view
- dismiss / pop / pop to root from the inspector
- resize the app's root container under simulated trait / safe-area / size-class overrides

In a simulator none of this needs changes to your app: turn on **Runtime Integration** for the simulator and run your app from Xcode as usual. It comes up with the agent loaded and the debugger still attached. See [`docs/runtime-integration.md`](docs/runtime-integration.md).

See [`docs/plan.md`](../../.claude/plans/you-are-a-senior-piped-bubble.md) for the full architecture and MVP phases.

## Repo layout

```
Voly/                          ─ macOS host app (SwiftUI, AppKit bridges)
Packages/VolyCore/             ─ Local SwiftPM package
  Sources/VolyCodables/        ─ Codable wrappers for CG types
  Sources/VolyModels/          ─ ViewNode, LayerProps, ConstraintNode, …
  Sources/VolyProtocol/        ─ Command / Response / Event / framing
  Sources/VolyAgent/           ─ iOS-only runtime agent (bootstraps, serves WS)
  Sources/VolyHost/            ─ macOS-side simulator integration, discovery, source lookup
  Sources/volyctl/             ─ CLI over the same host code, for scripting
LoaderShim/                    ─ ObjC constructor that boots the agent when injected
LaunchBridge/                  ─ simulator-only dylib loaded into runningboardd
SampleApp/                     ─ iOS dogfood app; links VolyAgent
scripts/integration-test.sh    ─ end-to-end check against a booted simulator
```

## Targets and schemes

| Target      | Platform       | Purpose                                    |
| ----------- | -------------- | ------------------------------------------ |
| `Voly`      | macOS          | Inspector UI. Links `VolyCore` (SPM).      |
| `SampleApp` | iOS            | Dogfood host. Links `VolyAgent` (SPM).     |
| `VolyCore`  | all            | Shared protocol / models library product.  |
| `VolyAgent` | iOS            | Runtime inspector SDK library product.     |
| `VolyHost`  | macOS          | Simulator integration + host-side logic.   |
| `VolyAgentDylib` | iOS Simulator | The agent as an injectable dylib.      |
| `VolyLaunchBridge` | iOS Simulator | Launch bridge for the simulator's runningboardd. |

Building `Voly` builds both simulator dylibs and embeds them in `Voly.app/Contents/Resources`.

## Running

1. Build and run `Voly` on macOS. It lives in the menu bar; ⌃⌥⌘V shows the inspector.
2. Boot a simulator and turn on **Runtime Integration** for it (menu bar, or the switch in the inspector's Tree tab).
3. Run any app in that simulator — from Xcode, the home screen, or `simctl`. It appears under its simulator and Voly connects.

To try it with the bundled sample:

```sh
xcodebuild -project Voly.xcodeproj -scheme SampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath /tmp/VolyDerivedData build
xcrun simctl install booted \
  /tmp/VolyDerivedData/Build/Products/Debug-iphonesimulator/SampleApp.app
xcrun simctl launch booted com.latifatci.VolySampleApp
```

## Safety model

- Runtime integration is off until you enable it, per simulator, and never applies to physical devices. It is removed when you turn it off, quit Voly, or shut the simulator down.
- Voly does not terminate or relaunch apps on its own. The one relaunch action is explicit and asks first.
- Injected agents listen on loopback only and require a per-process session token (from a `0600` file in the app's own container) before accepting any command. Voly also checks the handshake came from the pid it expected.
- The linked SDK is inert unless the host app is a Debug build **and** `VOLY_AGENT_ENABLED=1` (or `--voly-agent-enabled`) is set **and** your code calls `VolyAgent.start()`. In Release builds `VolyAgent.start()` is a no-op. SDK agents advertise over Bonjour on the LAN and are not token-protected.
- `VOLY_DISABLE=1` in an app's launch environment keeps the agent out of that launch.

## Integrating `VolyAgent` into your own iOS app

Optional. Simulator apps don't need it — runtime integration loads the agent for you. Link the SDK when you want the resizable preview (`VolyAgent.wrap`), custom property registration, or a device build.

1. Add this package as a local SwiftPM dependency (or point at its repo) and link the `VolyAgent` library product into your app target.
2. At scene setup, wrap your root view controller with `VolyAgent.wrap(original:)`:

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

3. Add `NSBonjourServices = ["_voly-agent._tcp"]` and `NSLocalNetworkUsageDescription = "..."` to your Info.plist (Debug only is fine — the agent never starts in Release).

4. Launch with `VOLY_AGENT_ENABLED=1` in the environment when you want the agent active.

### Registering custom inspectable properties

If your custom view has pure-Swift properties the ObjC runtime can't see, register them explicitly:

```swift
VolyAgent.register(BadgeView.self, property: "badgeText", type: .string,
    get: { .string($0.badgeText) },
    set: { view, value in
        if case .string(let s) = value { view.badgeText = s }
    })
```

## What works today

The phases from the plan that are *implemented and wired end-to-end*:

- **Phase 0 — Bootstrap**: SPM package created, Xcode project updated, both targets build cleanly.
- **Phase 1 — Transport + handshake**: Bonjour advertise, WebSocket server on iOS, WebSocket client on macOS, handshake/ping.
- **Phase 2 — Hierarchy read**: `HierarchyTraversal`, `SnapshotBuilder`, `ObjectRegistry`, SwiftUI `HierarchyBrowser`.
- **Phase 3 — Property inspection + editing**: `LayerProps` snapshot, UIView/CALayer mutation, type-aware PropertyPanel.
- **Phase 4 — Visual pick + overlay**: `PickEngine` + `OverlayHost`, click-through selection.
- **Phase 5 — Constraints**: relevant-constraint walk, edit constant / priority / isActive.
- **Phase 6 — Custom properties**: runtime ObjC scan + registration API + panel.
- **Phase 7 — UserDefaults + URL tester**: both panels wired.
- **Phase 8 — Source navigation**: line-exact Jump to Source through LLDB's line tables, with file-name search as the fallback.
- **Phase 9 — Preview subsystem**: `PreviewHostVC` with iOS 17+ `traitOverrides`, size + safe-area + trait + layout direction controls, macOS PreviewControl panel.
- **Phase 10 — Hardening** and **Phase 11 — Device support**: designed for, not yet exercised. Real-device connection requires pairing UI (not in MVP).
- **Simulator runtime integration**: per-simulator launch bridge, automatic agent loading with the Xcode debug session preserved, live localization, screenshots, navigation actions. Verified on the iOS 18.3.1 and 26.2 simulator runtimes.

## What is intentionally deferred

- SwiftUI hierarchy introspection (UIKit-only in v1 as per the plan).
- TLS on the LAN transport (cheap to add — Info.plist `NSAppTransportSecurity` + self-signed cert in handshake).
- Resizable preview through the automatically loaded agent (it still needs `VolyAgent.wrap` in the app), and a preview panel in the inspector.
- Real-device support (transport and agent are LAN-clean; UI wiring for manual host:port pairing is future work).

## Useful commands

```sh
# Build and test the SPM package (macOS slice only)
(cd Packages/VolyCore && swift build && swift test)

# End-to-end check of runtime integration against a booted simulator
scripts/integration-test.sh <booted-simulator-udid>

# Build VolyAgent scheme for iOS Simulator
xcodebuild -scheme VolyAgent -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/VolyDerivedData -skipPackagePluginValidation build

# Build macOS host (also builds and embeds VolyAgent.dylib + VolyLaunchBridge.dylib)
xcodebuild -project Voly.xcodeproj -scheme Voly -destination 'platform=macOS' \
  -derivedDataPath /tmp/VolyDerivedData build

# Build SampleApp
xcodebuild -project Voly.xcodeproj -scheme SampleApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/VolyDerivedData build
```
