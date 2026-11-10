import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import VolyCodables
import VolyModels
import VolyProtocol
@testable import VolyHost

/// Stands in for a running Voly: canned apps, scripted answers, and a
/// record of everything the tools asked for.
private final class FakeInspector: MCPInspecting, @unchecked Sendable {
    private let lock = NSLock()
    var accessLevel = MCPAccess.full
    var appList: [MCPApp] = [FakeInspector.shop]
    var simulators: [MCPSimulator] = [FakeInspector.phone]
    var selected: (appID: String, viewID: ObjectID)?
    var answer: @Sendable (Command, String) async throws -> Response = { _, _ in .ack }

    private(set) var sent: [(command: Command, appID: String)] = []
    private(set) var selections: [(ObjectID, String)] = []
    private(set) var changedApps: [String] = []
    private(set) var relaunches: [(String, String)] = []
    private(set) var toolCalls: [String] = []

    static let shop = MCPApp(
        id: "peer-shop", name: "Shop", bundleIdentifier: "com.example.shop", pid: 100,
        simulatorUDID: "SIM-1", simulatorName: "iPhone 16", isShownInVoly: false
    )
    static let notes = MCPApp(
        id: "peer-notes", name: "Notes", bundleIdentifier: "com.example.notes", pid: 200,
        simulatorUDID: "SIM-1", simulatorName: "iPhone 16", isShownInVoly: false
    )
    static let phone = MCPSimulator(
        udid: "SIM-1", name: "iPhone 16", runtime: "iOS 18.3", integration: "apps launched here are inspectable",
        isIntegrationActive: true, appsWithoutAgent: ["com.example.legacy"]
    )

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var access: MCPAccess { get async { accessLevel } }
    func apps() async -> [MCPApp] { appList }
    func overview() async -> MCPOverview { MCPOverview(simulators: simulators, apps: appList) }

    func send(_ command: Command, to appID: String) async throws -> Response {
        locked { sent.append((command, appID)) }
        return try await answer(command, appID)
    }

    func selection() async -> (appID: String, viewID: ObjectID)? { selected }
    func select(view: ObjectID, in appID: String) async throws { locked { selections.append((view, appID)) } }
    func appDidChange(_ appID: String) async { locked { changedApps.append(appID) } }
    func relaunch(bundleIdentifier: String, simulatorUDID: String) async throws {
        locked {
            relaunches.append((bundleIdentifier, simulatorUDID))
            // A relaunch is a new process: new pid, new handle.
            appList = appList.map { app in
                guard app.bundleIdentifier == bundleIdentifier else { return app }
                return MCPApp(
                    id: app.id + "-relaunched", name: app.name, bundleIdentifier: app.bundleIdentifier, pid: 4242,
                    simulatorUDID: app.simulatorUDID, simulatorName: app.simulatorName, isShownInVoly: false
                )
            }
        }
    }
    func noteToolCall(_ name: String) async { locked { toolCalls.append(name) } }
}

final class MCPToolboxTests: XCTestCase {
    private let inspector = FakeInspector()

    private func toolbox(timeout: Duration = .seconds(5)) -> MCPToolbox {
        MCPToolbox(
            inspector: inspector,
            commandTimeout: timeout,
            resolveSource: { info in
                SourceLookup(locations: [SourceLocation(
                    className: info.className, moduleName: "Shop", role: .viewController,
                    path: "/src/CartViewController.swift", line: 42, lineOrigin: .declaration, method: .debugInfo
                )], note: nil)
            },
            captureSimulator: { _ in MCPToolboxTests.png(width: 120, height: 260) }
        )
    }

    private func call(_ name: String, _ arguments: JSONValue = [:], timeout: Duration = .seconds(5)) async throws -> MCPToolResult {
        let result = await toolbox(timeout: timeout).call(name, arguments: arguments)
        return try XCTUnwrap(result)
    }

    // MARK: Fixtures

    private static func node(
        _ id: ObjectID, _ className: String, _ frame: (Double, Double, Double, Double),
        children: [ViewDescription] = [], configure: (inout ViewDescription) -> Void = { _ in }
    ) -> ViewDescription {
        var node = ViewDescription(
            id: id, className: className,
            frame: CGRectCodable(x: frame.0, y: frame.1, width: frame.2, height: frame.3),
            isHidden: false, alpha: 1, clipsToBounds: false
        )
        node.children = children
        configure(&node)
        return node
    }

    private static func cartScreen(ancestors: [ViewAncestor]? = nil, roots: [ViewDescription]? = nil) -> ScreenDescription {
        let tree = node(1, "UIWindow", (0, 0, 393, 852), children: [
            node(2, "UIView", (0, 0, 393, 852), children: [
                node(3, "UILabel", (16, 100, 200, 24)) {
                    $0.text = "Your cart"
                    $0.font = "System Bold 20"
                    $0.accessibilityIdentifier = "cart.title"
                },
                node(4, "UIButton", (16, 700, 361, 50)) {
                    $0.text = "Check out"
                    $0.backgroundColor = "#007AFFFF"
                    $0.flags = [.truncated]
                },
                node(5, "_UIHostingView<CartRow>", (16, 140, 361, 60)) {
                    $0.accessibilityElements = [AccessibilityElementDescription(
                        label: "Espresso beans", value: "2", identifier: "row.beans", traits: ["staticText"],
                        frame: CGRectCodable(x: 16, y: 140, width: 361, height: 60)
                    )]
                },
            ]) { $0.viewController = "CartViewController" },
        ])
        return ScreenDescription(
            appName: "Shop", bundleIdentifier: "com.example.shop", screenSize: CGSizeCodable(width: 393, height: 852),
            scale: 3, orientation: .portrait, appearance: "light", contentSizeCategory: "L",
            topViewController: "CartViewController", roots: roots ?? [tree], ancestors: ancestors,
            viewCount: 5, isTruncated: false
        )
    }

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func describeRequests() -> [ScreenDescriptionRequest] {
        inspector.sent.compactMap { entry -> ScreenDescriptionRequest? in
            if case .describeScreen(let request) = entry.command { return request }
            return nil
        }
    }

    // MARK: Access

    func test_nothing_reaches_an_app_while_access_is_off() async throws {
        inspector.accessLevel = .off
        let result = try await call("get_screen")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("turned off"), result.text)
        XCTAssertTrue(inspector.sent.isEmpty)
        XCTAssertTrue(inspector.toolCalls.isEmpty)
    }

    func test_read_only_access_reads_but_does_not_change() async throws {
        inspector.accessLevel = .readOnly
        inspector.answer = { _, _ in .screenDescription(Self.cartScreen()) }
        let read = try await call("get_screen")
        XCTAssertFalse(read.isError, read.text)

        for tool in MCPToolbox.definitions where tool.changesApp {
            let sentBefore = inspector.sent.count
            let result = try await call(tool.name, ["view": 3, "property": "alpha", "value": 0.5, "action": "pop",
                                                    "language": "fr", "url": "shop://cart", "key": "k", "bundle_id": "b",
                                                    "constraint": 9, "constant": 1])
            XCTAssertTrue(result.isError, tool.name)
            XCTAssertTrue(result.text.contains("read-only"), result.text)
            XCTAssertEqual(inspector.sent.count, sentBefore, "\(tool.name) reached the app")
        }
        XCTAssertTrue(inspector.relaunches.isEmpty)
    }

    func test_every_reading_tool_is_marked_as_such() {
        let changing = Set(MCPToolbox.definitions.filter(\.changesApp).map(\.name))
        XCTAssertEqual(changing, ["set_property", "set_constraint", "navigate", "set_language", "open_url",
                                  "set_user_default", "relaunch_app"])
        XCTAssertEqual(Set(MCPToolbox.definitions.map(\.name)).count, MCPToolbox.definitions.count)
    }

    func test_an_unknown_tool_is_nil_and_tool_calls_are_noted() async throws {
        let nothing = await toolbox().call("teleport", arguments: [:])
        XCTAssertNil(nothing)
        _ = try await call("list_apps")
        XCTAssertEqual(inspector.toolCalls, ["list_apps"])
    }

    // MARK: Choosing the app

    func test_the_only_app_is_used_without_being_named() async throws {
        inspector.answer = { _, _ in .screenDescription(Self.cartScreen()) }
        _ = try await call("get_screen")
        XCTAssertEqual(inspector.sent.map(\.appID), ["peer-shop"])
    }

    func test_with_several_apps_the_one_shown_in_voly_is_the_default() async throws {
        let shownNotes = MCPApp(
            id: "peer-notes", name: "Notes", bundleIdentifier: "com.example.notes", pid: 200,
            simulatorUDID: "SIM-1", simulatorName: "iPhone 16", isShownInVoly: true
        )
        inspector.appList = [FakeInspector.shop, shownNotes]
        inspector.answer = { _, _ in .screenDescription(Self.cartScreen()) }
        _ = try await call("get_screen")
        _ = try await call("get_screen", ["app": "com.example.shop"])
        _ = try await call("get_screen", ["app": "NOTES"])
        _ = try await call("get_screen", ["app": 100])
        XCTAssertEqual(inspector.sent.map(\.appID), ["peer-notes", "peer-shop", "peer-notes", "peer-shop"])
    }

    func test_several_apps_and_none_shown_asks_which() async throws {
        inspector.appList = [FakeInspector.shop, FakeInspector.notes]
        let result = try await call("get_screen")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("com.example.shop") && result.text.contains("com.example.notes"), result.text)
        let wrong = try await call("get_screen", ["app": "com.example.nope"])
        XCTAssertTrue(wrong.isError)
        XCTAssertTrue(wrong.text.contains("No inspectable app matches"), wrong.text)
    }

    func test_no_app_explains_how_to_get_one() async throws {
        inspector.appList = []
        let result = try await call("get_screen")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("No inspectable app is running"), result.text)
    }

    func test_list_apps_shows_simulators_apps_and_what_needs_a_relaunch() async throws {
        let text = try await call("list_apps").text
        XCTAssertTrue(text.contains("- iPhone 16, iOS 18.3 (SIM-1): apps launched here are inspectable"), text)
        XCTAssertTrue(text.contains("com.example.legacy"), text)
        XCTAssertTrue(text.contains("- Shop  bundle=com.example.shop  pid=100  simulator=iPhone 16"), text)
    }

    // MARK: Reading

    func test_get_screen_passes_its_options_on_and_reports_tree_and_problems() async throws {
        inspector.answer = { _, _ in .screenDescription(Self.cartScreen()) }
        let text = try await call("get_screen", ["root": "#2", "max_depth": 3, "include_hidden": true]).text
        XCTAssertEqual(describeRequests(), [ScreenDescriptionRequest(rootID: 2, maxDepth: 3, includeHidden: true)])
        XCTAssertTrue(text.hasPrefix("Shop (com.example.shop) in iPhone 16\n"), text)
        XCTAssertTrue(text.contains("UILabel #3 16,100 200×24 \"Your cart\" font=System Bold 20 id=cart.title"), text)
        XCTAssertTrue(text.contains("~ \"Espresso beans\" value=\"2\" staticText"), text)
        XCTAssertTrue(text.contains("Possible problems (1):\n- text truncated: UIButton #4 \"Check out\""), text)
    }

    func test_get_view_gathers_layout_constraints_properties_and_source() async throws {
        var label = Self.node(3, "UILabel", (16, 100, 200, 24)) { $0.text = "Your cart" }
        label.layout = LayoutDetails(
            bounds: CGRectCodable(x: 0, y: 0, width: 200, height: 24), usesAutoLayout: true,
            intrinsicWidth: 96, intrinsicHeight: 24, huggingHorizontal: 251, huggingVertical: 250,
            compressionResistanceHorizontal: 750, compressionResistanceVertical: 750,
            safeAreaInsets: .zero, layoutMargins: .zero
        )
        let screen = Self.cartScreen(
            ancestors: [ViewAncestor(id: 1, className: "UIWindow", viewController: nil),
                        ViewAncestor(id: 2, className: "UIView", viewController: "CartViewController")],
            roots: [label]
        )
        inspector.answer = { command, _ in
            switch command {
            case .describeScreen: return .screenDescription(screen)
            case .getConstraints:
                return .constraints([
                    ConstraintNode(id: 60, firstItemID: 3, firstAttribute: .leading, relation: .equal, secondItemID: 2,
                                   secondAttribute: .leading, constant: 16, multiplier: 1, priority: 750, identifier: "title-leading",
                                   isActive: true, ownerID: 2, isSystemGenerated: false,
                                   summary: "UILabel.leading = UIView.leading × 1.0 + 16.0 @750.0"),
                    ConstraintNode(id: 61, firstItemID: 4, firstAttribute: .top, relation: .greaterThanOrEqual, secondItemID: 3,
                                   secondAttribute: .bottom, constant: 8, multiplier: 1, priority: 1000, identifier: nil,
                                   isActive: false, ownerID: 2, isSystemGenerated: true,
                                   summary: "UIButton.top >= UILabel.bottom × 1.0 + 8.0 @1000.0"),
                ])
            case .getProperties:
                return .properties(PropertyBag(
                    objectID: 3,
                    view: ["alpha": .double(1), "backgroundColor": .null],
                    layer: ["cornerRadius": .double(4)],
                    custom: [
                        CustomPropDescriptor(name: "numberOfLines", declaredType: .int, isReadOnly: false,
                                             source: .runtimeObjC, currentValue: .int(1)),
                        CustomPropDescriptor(name: "hasContent", declaredType: .bool, isReadOnly: true,
                                             source: .runtimeObjC, currentValue: .bool(true)),
                        CustomPropDescriptor(name: "attributedText", declaredType: .unknown, isReadOnly: false,
                                             source: .runtimeObjC, currentValue: .null),
                    ]
                ))
            case .resolveSource:
                return .sourceInfo(SourceInfo(className: "CartViewController", moduleName: "Shop", dsymUUID: nil,
                                              guessedRelativePath: nil))
            default: return .ack
            }
        }
        let text = try await call("get_view", ["view": 3]).text
        XCTAssertEqual(describeRequests(), [ScreenDescriptionRequest(rootID: 3, maxDepth: 1)])
        XCTAssertTrue(text.contains("Inside: UIWindow #1 › UIView #2 (CartViewController)"), text)
        XCTAssertTrue(text.contains("View controller: CartViewController"), text)
        XCTAssertTrue(text.contains("Layout: Auto Layout; bounds 0,0 200×24; intrinsic size 96×24; hugging H251 V250"), text)
        XCTAssertTrue(text.contains("- #60 Leading to UIView.leading + 16 (view #2) @750 \"title-leading\""), text)
        XCTAssertTrue(text.contains("- #61 (of view #4) Top ≥ UILabel.bottom + 8 (this view) [system] [inactive]"), text)
        XCTAssertTrue(text.contains("view: alpha=1, backgroundColor=nil"), text)
        XCTAssertTrue(text.contains("layer: cornerRadius=4"), text)
        XCTAssertTrue(text.contains("class-specific: numberOfLines=1, hasContent=true (read-only)"), text)
        XCTAssertFalse(text.contains("attributedText"), "unset values are left out")
        XCTAssertTrue(text.contains("- /src/CartViewController.swift:42  CartViewController (the view controller that owns it)"), text)

        let withoutSource = try await call("get_view", ["view": 3, "source": false]).text
        XCTAssertFalse(withoutSource.contains("Source"), withoutSource)
    }

    func test_text_typed_into_a_secure_field_is_not_passed_on() async throws {
        let field = Self.node(9, "UITextField", (16, 300, 361, 34)) {
            $0.text = "(secure text, 7 characters)"
            $0.state = ["secure"]
        }
        inspector.answer = { command, _ in
            switch command {
            case .describeScreen: return .screenDescription(Self.cartScreen(roots: [field]))
            case .getProperties:
                return .properties(PropertyBag(objectID: 9, view: [:], layer: [:], custom: [
                    CustomPropDescriptor(name: "text", declaredType: .string, isReadOnly: false,
                                         source: .runtimeObjC, currentValue: .string("hunter2")),
                    CustomPropDescriptor(name: "placeholder", declaredType: .string, isReadOnly: false,
                                         source: .runtimeObjC, currentValue: .string("Password")),
                ]))
            default: return .constraints([])
            }
        }
        let text = try await call("get_view", ["view": 9, "source": false]).text
        XCTAssertFalse(text.contains("hunter2"), text)
        XCTAssertTrue(text.contains("text=(hidden: secure text), placeholder=\"Password\""), text)
        XCTAssertTrue(text.contains("[secure]"), text)
    }

    func test_an_agent_too_old_to_describe_the_screen_is_explained() async throws {
        inspector.answer = { _, _ in throw InspectorError.internal("The data couldn’t be read because it isn’t in the correct format.") }
        let result = try await call("get_screen")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("older than this Voly") && result.text.contains("relaunch_app"), result.text)
    }

    func test_a_view_that_is_gone_says_to_read_the_screen_again() async throws {
        inspector.answer = { _, _ in throw InspectorError.objectGone(77) }
        let result = try await call("get_view", ["view": 77])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("#77") && result.text.contains("get_screen"), result.text)
    }

    func test_an_app_that_never_answers_times_out_with_a_likely_reason() async throws {
        inspector.answer = { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .ack
        }
        let started = Date()
        let result = try await call("get_screen", timeout: .milliseconds(200))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("paused in the debugger"), result.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_find_views_by_text_class_identifier_and_point() async throws {
        inspector.answer = { _, _ in .screenDescription(Self.cartScreen()) }
        let byText = try await call("find_views", ["text": "CART"]).text
        XCTAssertTrue(byText.contains("1 match:\nUILabel #3"), byText)
        XCTAssertTrue(byText.contains("— in CartViewController"), byText)

        let swiftUI = try await call("find_views", ["text": "espresso"]).text
        XCTAssertTrue(swiftUI.contains("~ \"Espresso beans\""), swiftUI)
        XCTAssertTrue(swiftUI.contains("inside _UIHostingView<CartRow> #5"), swiftUI)

        let byClass = try await call("find_views", ["class_name": "button"]).text
        XCTAssertTrue(byClass.contains("UIButton #4") && !byClass.contains("UILabel #3"), byClass)

        let byIdentifier = try await call("find_views", ["accessibility_id": "row."]).text
        XCTAssertTrue(byIdentifier.contains("id=row.beans"), byIdentifier)

        let atPoint = try await call("find_views", ["x": 30, "y": 710]).text
        let lines = atPoint.split(separator: "\n")
        XCTAssertTrue(lines[0].contains("innermost first"), atPoint)
        XCTAssertTrue(lines[1].hasPrefix("UIButton #4"), atPoint)
        XCTAssertTrue(lines.last?.hasPrefix("UIWindow #1") ?? false, atPoint)

        let problems = try await call("find_views", ["problems_only": true]).text
        XCTAssertTrue(problems.contains("1 match") && problems.contains("UIButton #4"), problems)

        let none = try await call("find_views", ["text": "wishlist"]).text
        XCTAssertEqual(none, "No matching views on the current screen.")
        let empty = try await call("find_views")
        XCTAssertTrue(empty.isError)
    }

    func test_selection_is_read_from_voly_and_set_in_voly() async throws {
        let nothing = try await call("get_selection").text
        XCTAssertTrue(nothing.contains("Nothing is selected"), nothing)

        inspector.selected = ("peer-shop", 3)
        inspector.answer = { command, _ in
            if case .describeScreen = command { return .screenDescription(Self.cartScreen()) }
            throw InspectorError.unavailable("not in this test")
        }
        let selected = try await call("get_selection", ["source": false]).text
        XCTAssertTrue(selected.hasPrefix("Selected in Voly (Shop):"), selected)
        XCTAssertEqual(describeRequests().last?.rootID, 3)

        let chosen = try await call("select_view", ["view": 4])
        XCTAssertFalse(chosen.isError, chosen.text)
        XCTAssertEqual(inspector.selections.map(\.0), [4])
        XCTAssertEqual(inspector.selections.map(\.1), ["peer-shop"])
    }

    // MARK: Screenshots

    func test_screenshots_are_scaled_down_and_say_how_points_map_to_pixels() async throws {
        let capture = Self.png(width: 1179, height: 2556)
        inspector.answer = { command, _ in
            switch command {
            case .captureScreenshot:
                return .screenshot(ScreenshotImage(png: capture, pixelWidth: 1179, pixelHeight: 2556, scale: 3, orientation: .portrait))
            case .screenInfo:
                return .screenInfo(ScreenInfo(orientation: .portrait, scale: 3))
            default: return .ack
            }
        }
        let app = try await call("screenshot", ["max_dimension": 852])
        XCTAssertTrue(app.text.contains("393×852 px (scaled down from 1179×2556). 1 pt = 1.00 px"), app.text)
        guard case .image(let base64, let mime)? = app.content.last else { return XCTFail("no image") }
        XCTAssertEqual(mime, "image/png")
        let fitted = try XCTUnwrap(MCPImage.fit(png: try XCTUnwrap(Data(base64Encoded: base64)), maxDimension: 10_000))
        XCTAssertEqual([fitted.width, fitted.height], [393, 852])

        _ = try await call("screenshot", ["view": 4])
        guard case .captureScreenshot(.view(4))? = inspector.sent.last?.command else {
            return XCTFail("a view id alone means target=view")
        }

        let simulator = try await call("screenshot", ["target": "simulator"])
        XCTAssertTrue(simulator.text.contains("the whole display of iPhone 16"), simulator.text)
        XCTAssertTrue(simulator.text.contains("120×260 px"), simulator.text)

        let bad = try await call("screenshot", ["target": "moon"])
        XCTAssertTrue(bad.isError)
    }

    func test_images_within_the_limit_are_left_alone() throws {
        let small = Self.png(width: 100, height: 50)
        let fitted = try XCTUnwrap(MCPImage.fit(png: small, maxDimension: 200))
        XCTAssertEqual(fitted.png, small)
        XCTAssertNil(MCPImage.fit(png: Data("not a png".utf8), maxDimension: 200))
    }

    // MARK: Changing

    private func answerWithProperties() {
        inspector.answer = { command, _ in
            switch command {
            case .getProperties:
                return .properties(PropertyBag(
                    objectID: 3,
                    view: ["alpha": .double(1), "isHidden": .bool(false), "backgroundColor": .null,
                           "tintColor": .color(CGColorCodable(red: 0, green: 0, blue: 1, alpha: 1))],
                    layer: ["cornerRadius": .double(0),
                            "shadowOffset": .size(CGSizeCodable(width: 0, height: -3))],
                    custom: [
                        CustomPropDescriptor(name: "text", declaredType: .string, isReadOnly: false,
                                             source: .runtimeObjC, currentValue: .string("Your cart")),
                        CustomPropDescriptor(name: "highlightedTextColor", declaredType: .color, isReadOnly: false,
                                             source: .runtimeObjC, currentValue: .null),
                        CustomPropDescriptor(name: "hasContent", declaredType: .bool, isReadOnly: true,
                                             source: .runtimeObjC, currentValue: .bool(true)),
                    ]
                ))
            default: return .ack
            }
        }
    }

    private func lastPropertyRequest() -> SetPropertyRequest? {
        for entry in inspector.sent.reversed() {
            if case .setProperty(let request) = entry.command { return request }
        }
        return nil
    }

    func test_set_property_shapes_the_value_like_the_property() async throws {
        answerWithProperties()
        var result = try await call("set_property", ["view": 3, "property": "tintColor", "value": "#FF3B30"])
        XCTAssertFalse(result.isError, result.text)
        var request = try XCTUnwrap(lastPropertyRequest())
        XCTAssertEqual(request.scope, .view)
        XCTAssertEqual(request.change.value, .color(CGColorCodable(red: 1, green: 59.0 / 255, blue: 48.0 / 255, alpha: 1)))
        XCTAssertEqual(inspector.changedApps, ["peer-shop"])

        result = try await call("set_property", ["view": 3, "property": "cornerRadius", "value": 12])
        request = try XCTUnwrap(lastPropertyRequest())
        XCTAssertEqual(request.scope, .layer)
        XCTAssertEqual(request.change.value, .double(12))

        result = try await call("set_property", ["view": 3, "property": "text", "value": "#FFF is a color"])
        request = try XCTUnwrap(lastPropertyRequest())
        XCTAssertEqual(request.scope, .custom)
        XCTAssertEqual(request.change.value, .string("#FFF is a color"), "a string property keeps strings as they are")

        result = try await call("set_property", ["view": 3, "property": "highlightedTextColor", "value": "#0F08"])
        XCTAssertFalse(result.isError, result.text)
        result = try await call("set_property", ["view": 3, "property": "shadowOffset", "value": ["width": 2, "height": 4]])
        XCTAssertEqual(lastPropertyRequest()?.change.value, .size(CGSizeCodable(width: 2, height: 4)))
        result = try await call("set_property", ["view": 3, "property": "backgroundColor", "value": "#00FF0080"])
        XCTAssertEqual(lastPropertyRequest()?.change.value, .color(CGColorCodable(red: 0, green: 1, blue: 0, alpha: 128.0 / 255)))
    }

    func test_set_property_refuses_what_cannot_work_and_says_why() async throws {
        answerWithProperties()
        let wrongType = try await call("set_property", ["view": 3, "property": "alpha", "value": "half"])
        XCTAssertTrue(wrongType.isError)
        XCTAssertEqual(wrongType.text, "alpha takes a number.")
        let readOnly = try await call("set_property", ["view": 3, "property": "hasContent", "value": false])
        XCTAssertEqual(readOnly.text, "hasContent is read-only.")
        let unknown = try await call("set_property", ["view": 3, "property": "sparkle", "value": 1])
        XCTAssertTrue(unknown.text.contains("no settable property \"sparkle\"") && unknown.text.contains("cornerRadius"), unknown.text)
        XCTAssertNil(lastPropertyRequest())
        XCTAssertTrue(inspector.changedApps.isEmpty)
    }

    func test_set_constraint_needs_something_to_change() async throws {
        let nothing = try await call("set_constraint", ["view": 3, "constraint": 60])
        XCTAssertTrue(nothing.isError)
        let changed = try await call("set_constraint", ["view": 3, "constraint": 60, "constant": 24, "active": false])
        XCTAssertFalse(changed.isError, changed.text)
        guard case .setConstraint(let request)? = inspector.sent.first(where: {
            if case .setConstraint = $0.command { return true } else { return false }
        })?.command else { return XCTFail("no constraint request") }
        XCTAssertEqual(request.constraintID, 60)
        XCTAssertEqual(request.anchorObjectID, 3)
        XCTAssertEqual(request.change.constant, 24)
        XCTAssertEqual(request.change.isActive, false)
        XCTAssertNil(request.change.priority)
    }

    func test_navigation_that_cannot_happen_is_an_error_with_the_reason() async throws {
        inspector.answer = { _, _ in
            .navigationResult(NavigationResult(action: .pop, performed: false, message: "Already at the root screen.",
                                               state: .unavailable))
        }
        let result = try await call("navigate", ["action": "pop"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Not done: Already at the root screen.")
        let bad = try await call("navigate", ["action": "sideways"])
        XCTAssertTrue(bad.isError)
    }

    func test_set_language_follows_the_language_unless_told_otherwise() async throws {
        inspector.answer = { _, _ in
            .localization(LocalizationState(
                available: [LocalizationLanguage(code: "ar", displayName: "Arabic", isRightToLeft: true)],
                developmentLanguage: "en", systemLanguage: "en", activeOverride: "ar", layoutDirectionMode: .followLanguage,
                isLayoutRightToLeft: true, interceptedLookups: [], lastRefresh: nil
            ))
        }
        let result = try await call("set_language", ["language": "ar"])
        XCTAssertTrue(result.text.contains("ar (set through Voly); layout is right-to-left"), result.text)
        _ = try await call("set_language", ["language": "system"])
        _ = try await call("set_language", ["language": "ar", "layout_direction": "left_to_right"])
        let requests = inspector.sent.compactMap { entry -> LocalizationOverrideRequest? in
            if case .setLocalizationOverride(let request) = entry.command { return request }
            return nil
        }
        XCTAssertEqual(requests, [
            LocalizationOverrideRequest(language: "ar", layoutDirectionMode: .followLanguage, refreshUI: true),
            LocalizationOverrideRequest(language: nil, layoutDirectionMode: .system, refreshUI: true),
            LocalizationOverrideRequest(language: "ar", layoutDirectionMode: .leftToRight, refreshUI: true),
        ])
    }

    func test_user_defaults_are_listed_filtered_set_and_removed() async throws {
        inspector.answer = { command, _ in
            if case .userDefaultsList = command {
                return .userDefaults([
                    UserDefaultsItem(suite: "standard", key: "onboarding.done", type: .bool, value: .bool(true)),
                    UserDefaultsItem(suite: "standard", key: "cart.count", type: .int, value: .int(3)),
                ])
            }
            return .ack
        }
        let listed = try await call("get_user_defaults", ["contains": "CART"]).text
        XCTAssertEqual(listed, "1 of 2 keys:\ncart.count (int) = 3")
        _ = try await call("set_user_default", ["key": "cart.count", "value": 5])
        _ = try await call("set_user_default", ["key": "cart.count", "value": nil])
        guard case .userDefaultsSet(let set) = inspector.sent[1].command,
              case .userDefaultsDelete(_, let removed) = inspector.sent[2].command
        else { return XCTFail("\(inspector.sent.map(\.command))") }
        XCTAssertEqual(set.value, .int(5))
        XCTAssertEqual(removed, "cart.count")
    }

    func test_relaunch_goes_to_the_simulator_the_app_is_in() async throws {
        let result = try await call("relaunch_app", ["bundle_id": "com.example.shop"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(inspector.relaunches.map(\.0), ["com.example.shop"])
        XCTAssertEqual(inspector.relaunches.map(\.1), ["SIM-1"])
        XCTAssertTrue(result.text.contains("pid=4242"), "reports the new process, not the one it replaced: \(result.text)")
        let unknown = try await call("relaunch_app", ["bundle_id": "com.example.shop", "simulator": "iPad"])
        XCTAssertTrue(unknown.isError)
    }

    func test_hex_colors() {
        XCTAssertEqual(MCPToolbox.color(hex: "#fff"), CGColorCodable(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(MCPToolbox.color(hex: "#00000000"), CGColorCodable(red: 0, green: 0, blue: 0, alpha: 0))
        XCTAssertNil(MCPToolbox.color(hex: "red"))
        XCTAssertNil(MCPToolbox.color(hex: "#12345"))
    }
}
