#if DEBUG
import AppKit
import Network
import SwiftUI
import VolyCodables
import VolyHost
import VolyModels
import VolyProtocol

/// Renders every inspector tab from fixture data into PNG files:
///
///     VOLY_UI_PREVIEW=/some/dir Voly.app/Contents/MacOS/Voly
///
/// A way to look at the UI without a simulator, an app, or clicking through
/// states — and without disturbing a Voly that is already running, because
/// the preview session never discovers or connects to anything.
@MainActor
enum UIPreviewRenderer {
    private static let size = CGSize(width: 440, height: 720)

    static func run(outputDirectory: URL) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let connected = makeSession(connected: true)
        for tab in DetailTab.allCases {
            await render(connected, tab: tab, to: outputDirectory.appendingPathComponent("\(tab.rawValue).png"))
        }
        let empty = makeSession(connected: false)
        await render(empty, tab: .hierarchy, to: outputDirectory.appendingPathComponent("empty.png"))
        await render(empty, tab: .layout, to: outputDirectory.appendingPathComponent("no-selection.png"))
    }

    private static func render(_ session: InspectorSession, tab: DetailTab, to url: URL) async {
        let controller = InspectorWindowController(session: session, initialTab: tab)
        let panel = controller.panel
        // Far off every display: laid out and drawn, never seen.
        panel.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), display: true)
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        panel.orderOut(nil)
    }

    // MARK: - Fixtures

    private static let simulatorA = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let simulatorB = "BBBBBBBB-0000-0000-0000-000000000002"
    private static let labelID: ObjectID = 12

    private static func makeSession(connected: Bool) -> InspectorSession {
        let session = InspectorSession(startDiscovery: false)
        session.simulators.setPreview(simulators: simulators(connected: connected))
        guard connected else { return session }

        session.connections.updateFileDiscoveredPeers([
            DiscoveredAgent(deviceUDID: simulatorA, bundleIdentifier: "com.example.Storefront",
                            processName: "Storefront", pid: 4101, port: 51000, issuedAt: Date(), token: "t"),
            DiscoveredAgent(deviceUDID: simulatorB, bundleIdentifier: "com.example.Storefront",
                            processName: "Storefront", pid: 4202, port: 51001, issuedAt: Date(), token: "t"),
        ])
        let state = session.state
        state.connectionStatus = .connected
        state.activePeerID = "file:\(simulatorA):com.example.Storefront:4101"
        state.connectedPeerIDs = Set(session.connections.peers.map(\.id))
        state.agent = HandshakeAccepted(
            protocolVersion: 1, sessionID: UUID(), agentName: "VolyAgent", agentVersion: "0.1.0",
            bundleIdentifier: "com.example.Storefront", processName: "Storefront",
            pid: 4101, simulatorUDID: simulatorA,
            capabilities: AgentCapabilities(
                injectionMode: .injected, previewHost: false, localization: true,
                screenshots: true, navigation: true, sourceSymbols: true)
        )
        state.hierarchy = hierarchy()
        state.expandedNodeIDs = [1, 2, 3, 4, 10]
        state.selectedViewID = labelID
        state.pickModeActive = true
        state.navigation = NavigationState(
            canDismiss: false, canPop: true, canPopToRoot: true,
            unavailableReasons: ["dismiss": "Nothing is presented."],
            topViewController: "ProductViewController", navigationStackDepth: 2, isTransitioning: false)
        state.localization = LocalizationState(
            available: [
                .init(code: "ar", displayName: "Arabic", isRightToLeft: true),
                .init(code: "en", displayName: "English", isRightToLeft: false),
                .init(code: "fr", displayName: "French", isRightToLeft: false),
            ],
            developmentLanguage: "en", systemLanguage: "en", activeOverride: nil,
            layoutDirectionMode: .system, isLayoutRightToLeft: false, interceptedLookups: [], lastRefresh: nil)
        state.sourceLookup = .resolved(labelID, SourceLookup(locations: [
            SourceLocation(className: "ProductViewController", moduleName: "Storefront", role: .viewController,
                           path: "/Users/dev/Storefront/Sources/ProductViewController.swift", line: 42,
                           lineOrigin: .declaration, method: .debugInfo),
        ], note: nil))
        state.constraints = constraints()
        state.propertyBag = PropertyBag(
            objectID: labelID,
            view: [
                "alpha": .double(1), "isHidden": .bool(false), "clipsToBounds": .bool(false),
                "isUserInteractionEnabled": .bool(false), "tag": .int(0),
                "text": .string("Trail Runner 2"),
                "tintColor": .color(CGColorCodable(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)),
                "contentMode": .int(7),
            ],
            layer: [
                "cornerRadius": .double(0), "borderWidth": .double(0), "masksToBounds": .bool(false),
                "opacity": .double(1), "shadowRadius": .double(3),
                "shadowOffset": .size(CGSizeCodable(width: 0, height: -3)),
            ],
            custom: [
                CustomPropDescriptor(name: "badgeText", declaredType: .string, isReadOnly: false,
                                     source: .registered, currentValue: .string("New")),
            ]
        )
        state.userDefaults = [
            UserDefaultsItem(suite: "", key: "onboarding.completed", type: .bool, value: .bool(true)),
            UserDefaultsItem(suite: "", key: "cart.itemCount", type: .int, value: .int(3)),
            UserDefaultsItem(suite: "", key: "user.displayName", type: .string, value: .string("Latif")),
            UserDefaultsItem(suite: "", key: "catalog.lastSyncInterval", type: .double, value: .double(1794.5)),
        ]
        state.urlHistory = [URL(string: "storefront://product/4411")!, URL(string: "storefront://cart")!]
        return session
    }

    private static func simulators(connected: Bool) -> [VolySimulatorManager.Simulator] {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-18-3": [{"udid": "\(simulatorA)", "name": "iPhone 16 Pro", "state": "Booted"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{"udid": "\(simulatorB)", "name": "iPhone 17 Pro", "state": "Booted"}]
        }}
        """
        let devices = (try? SimInventory.parseDevices(data: Data(json.utf8))) ?? []
        return devices.map { device in
            let isA = device.udid == simulatorA
            var apps = [VolySimulatorManager.RunningAppEntry(
                bundleIdentifier: "com.example.Storefront", pid: isA ? 4101 : 4202,
                isInstrumented: true, instrumentsOnNextLaunch: true)]
            if !isA {
                apps.append(.init(bundleIdentifier: "com.example.Notes", pid: 4203,
                                  isInstrumented: false, instrumentsOnNextLaunch: true))
            }
            return VolySimulatorManager.Simulator(
                device: device,
                integration: connected ? activeState(udid: device.udid) : .inactive,
                runningApps: connected ? apps : [],
                isBusy: false,
                error: nil
            )
        }
    }

    private static func activeState(udid: String) -> VolyInjectionCoordinator.State {
        let plist: [String: Any] = [
            "bridgeVersion": "1", "pid": 1, "hookInstalled": true,
            "simulatorUDID": udid, "loadedAt": Date(),
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              let status = try? PropertyListDecoder().decode(BridgeStatus.self, from: data)
        else { return .inactive }
        return .active(status)
    }

    private static func constraints() -> [ConstraintNode] {
        func make(_ id: ObjectID, _ first: LayoutAttribute, _ second: LayoutAttribute, constant: Double,
                  priority: Float = 1000, system: Bool = false, summary: String) -> ConstraintNode {
            ConstraintNode(
                id: id, firstItemID: labelID, firstAttribute: first, relation: .equal,
                secondItemID: second == .notAnAttribute ? nil : 11, secondAttribute: second,
                constant: constant, multiplier: 1, priority: priority, identifier: nil,
                isActive: true, ownerID: 10, isSystemGenerated: system, summary: summary)
        }
        return [
            make(101, .leading, .trailing, constant: 12,
                 summary: "UILabel.leading = UIImageView.trailing × 1.0 + 12.0 @1000.0"),
            make(102, .centerY, .centerY, constant: 0,
                 summary: "UILabel.centerY = UIImageView.centerY × 1.0 + 0.0 @1000.0"),
            make(103, .width, .notAnAttribute, constant: 173, priority: 750,
                 summary: "UILabel.width = nil.notAnAttribute × 1.0 + 173.0 @750.0"),
            make(104, .height, .notAnAttribute, constant: 20.333, system: true,
                 summary: "UILabel.height = nil.notAnAttribute × 1.0 + 20.333 @1000.0"),
        ]
    }

    private static func hierarchy() -> HierarchySnapshot {
        func node(_ id: ObjectID, _ className: String, _ frame: CGRect, identifier: String? = nil,
                  hidden: Bool = false, inherits: [String]? = nil, _ children: [ViewNode] = []) -> ViewNode {
            ViewNode(
                id: id, className: className, moduleName: nil, accessibilityIdentifier: identifier,
                owningViewControllerID: nil, frame: CGRectCodable(frame),
                bounds: CGRectCodable(CGRect(origin: .zero, size: frame.size)),
                center: CGPointCodable(CGPoint(x: frame.midX, y: frame.midY)),
                isHidden: hidden, alpha: 1,
                layer: LayerProps(
                    cornerRadius: 0, borderWidth: 0, borderColor: nil, shadowColor: nil, shadowOpacity: 0,
                    shadowRadius: 3, shadowOffset: CGSizeCodable(width: 0, height: -3), masksToBounds: false,
                    shouldRasterize: false, rasterizationScale: 1, opacity: 1, isOpaque: false,
                    backgroundColor: nil, contentsScale: 3),
                tintColor: nil, clipsToBounds: false, contentMode: 0, constraintIDs: [],
                childIDs: children.map(\.id), childrenInline: children,
                classInheritance: inherits, hasNonIdentityTransform: false, windowFrame: CGRectCodable(frame))
        }
        let card = node(10, "ProductCardView", CGRect(x: 16, y: 120, width: 361, height: 96), identifier: "product_card", [
            node(11, "UIImageView", CGRect(x: 12, y: 16, width: 64, height: 64), identifier: "product_image"),
            node(labelID, "UILabel", CGRect(x: 88, y: 38, width: 173, height: 20.333), identifier: "product_title",
                 inherits: ["UILabel", "UIView", "UIResponder", "NSObject"]),
            node(13, "UILabel", CGRect(x: 88, y: 60, width: 120, height: 16), identifier: "product_price"),
            node(14, "UIButton", CGRect(x: 289, y: 30, width: 60, height: 36), identifier: "add_to_cart"),
            node(15, "BadgeView", CGRect(x: 300, y: 8, width: 48, height: 18), hidden: true),
        ])
        let window = node(1, "UIWindow", CGRect(x: 0, y: 0, width: 393, height: 852), [
            node(2, "UITransitionView", CGRect(x: 0, y: 0, width: 393, height: 852), [
                node(3, "UILayoutContainerView", CGRect(x: 0, y: 0, width: 393, height: 852), [
                    node(4, "UIScrollView", CGRect(x: 0, y: 0, width: 393, height: 852), [
                        card,
                        node(20, "ProductCardView", CGRect(x: 16, y: 228, width: 361, height: 96)),
                        node(21, "UIStackView", CGRect(x: 16, y: 340, width: 361, height: 44), identifier: "filters"),
                    ]),
                    node(5, "UINavigationBar", CGRect(x: 0, y: 59, width: 393, height: 44)),
                ]),
            ]),
        ])
        return HierarchySnapshot(
            scenes: [SceneNode(id: 900, role: "UIWindowSceneSessionRoleApplication", title: nil,
                               windowIDs: [1], windowsInline: [window])],
            issuedAt: Date())
    }
}
#endif
