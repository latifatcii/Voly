# Voly

Live iOS inspector / editor — a macOS host that connects to a running UIKit app in the iOS Simulator (or on device) and lets a developer:

- inspect the full view hierarchy
- visually pick views
- edit UIView / CALayer properties live
- edit Auto Layout constraints
- inspect custom / @IBInspectable properties
- edit UserDefaults
- test deep links
- jump to source in Xcode
- resize the app's root container under simulated trait / safe-area / size-class overrides

See [`docs/plan.md`](../../.claude/plans/you-are-a-senior-piped-bubble.md) for the full architecture and MVP phases.

## Repo layout

```
Voly/                          ─ macOS host app (SwiftUI, AppKit bridges)
Packages/VolyCore/             ─ Local SwiftPM package
  Sources/VolyCodables/        ─ Codable wrappers for CG types
  Sources/VolyModels/          ─ ViewNode, LayerProps, ConstraintNode, …
  Sources/VolyProtocol/        ─ Command / Response / Event / framing
  Sources/VolyAgent/           ─ iOS-only runtime SDK (bootstraps, serves WS)
SampleApp/                     ─ iOS dogfood app; links VolyAgent
```

## Targets and schemes

| Target      | Platform       | Purpose                                    |
| ----------- | -------------- | ------------------------------------------ |
| `Voly`      | macOS          | Inspector UI. Links `VolyCore` (SPM).      |
| `SampleApp` | iOS            | Dogfood host. Links `VolyAgent` (SPM).     |
| `VolyCore`  | all            | Shared protocol / models library product.  |
| `VolyAgent` | iOS            | Runtime inspector SDK library product.     |

## Running the MVP

1. **Build and launch `SampleApp` in the iOS Simulator with the agent enabled.**

   In Xcode: select the `SampleApp` scheme and the booted iPhone simulator. Open the scheme editor → *Run* → *Arguments* → *Environment Variables* → add `VOLY_AGENT_ENABLED = 1`. Hit Run.

   Or from the CLI:

   ```sh
   xcodebuild -project Voly.xcodeproj -scheme SampleApp \
     -destination 'platform=iOS Simulator,name=iPhone 17' \
     -derivedDataPath /tmp/VolyDerivedData build

   xcrun simctl install booted \
     /tmp/VolyDerivedData/Build/Products/Debug-iphonesimulator/SampleApp.app

   SIMCTL_CHILD_VOLY_AGENT_ENABLED=1 xcrun simctl launch \
     --terminate-running-process booted com.latifatci.VolySampleApp
   ```

2. **Confirm the agent is advertising:**

   ```sh
   dns-sd -B _voly-agent._tcp local
   # Expect an "Add" row for "SampleApp — iPhone 17"
   ```

3. **Build and run `Voly` on macOS.** The sidebar lists discovered agents under "Discovered Apps". Click one to connect.

## Safety model

- The iOS SDK is inert unless **all three** gates pass:
  - the host app is a Debug build (`#if DEBUG`)
  - the launch env var `VOLY_AGENT_ENABLED=1` is set (or `--voly-agent-enabled` launch arg)
  - your code explicitly calls `VolyAgent.start()`
- In Release builds, `VolyAgent.start()` is a no-op and the server code is not reachable.
- The macOS host's entitlements include `com.apple.security.network.client` only; the host app does not serve the network.
- On iOS, `NSBonjourServices` and `NSLocalNetworkUsageDescription` are populated in the SampleApp's Info.plist so the agent can register on the LAN.

## Integrating `VolyAgent` into your own iOS app

Two steps:

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
- **Phase 8 — Source navigation**: class→file resolver with workspace-root `mdfind` fallback and `xed` launcher (build-plugin indexer is a Phase 8.5).
- **Phase 9 — Preview subsystem**: `PreviewHostVC` with iOS 17+ `traitOverrides`, size + safe-area + trait + layout direction controls, macOS PreviewControl panel.
- **Phase 10 — Hardening** and **Phase 11 — Device support**: designed for, not yet exercised. Real-device connection requires pairing UI (not in MVP).

## What is intentionally deferred

- SwiftUI hierarchy introspection (UIKit-only in v1 as per the plan).
- Line-accurate source navigation (only file-level jumps; line numbers require DWARF).
- TLS on the LAN transport (cheap to add — Info.plist `NSAppTransportSecurity` + self-signed cert in handshake).
- `simctl` polish (`SimBridge` scaffolding exists but is not yet surfaced in UI).
- Build-time class-index SwiftPM plugin (runtime resolver uses `mdfind` until it lands).
- Real-device support (transport and agent are LAN-clean; UI wiring for manual host:port pairing is future work).

## Useful commands

```sh
# Build the SPM package standalone (macOS slice only)
(cd Packages/VolyCore && swift build)

# Build VolyAgent scheme for iOS Simulator
xcodebuild -scheme VolyAgent -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/VolyDerivedData -skipPackagePluginValidation build

# Build macOS host
xcodebuild -project Voly.xcodeproj -scheme Voly -destination 'platform=macOS' \
  -derivedDataPath /tmp/VolyDerivedData build

# Build SampleApp
xcodebuild -project Voly.xcodeproj -scheme SampleApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/VolyDerivedData build
```
