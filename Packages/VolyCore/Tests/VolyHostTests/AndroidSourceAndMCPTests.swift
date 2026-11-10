import Foundation
import XCTest
import VolyCodables
import VolyModels
import VolyProtocol
@testable import VolyHost

final class AndroidSourceResolverTests: XCTestCase {
    private let files: [String: String] = [
        "/work/shop/app/src/main/java/com/example/shop/ui/CartFragment.kt": """
            package com.example.shop.ui

            import androidx.fragment.app.Fragment

            // class CartFragment used to live elsewhere
            class CartFragment : Fragment(R.layout.fragment_cart)
            """,
        "/work/other/app/src/main/java/com/other/CartFragment.kt": "package com.other\n\nclass CartFragment\n",
        "/work/shop/app/build/generated/CartFragment.kt": "package com.example.shop.ui\nclass CartFragment\n",
        "/work/shop/app/src/main/java/com/example/shop/MainActivity.java": """
            package com.example.shop;

            public class MainActivity extends AppCompatActivity {
            }
            """,
        "/work/shop/app/src/main/res/layout/fragment_cart.xml": """
            <LinearLayout xmlns:android="http://schemas.android.com/apk/res/android">
                <TextView
                    android:id="@+id/cart_total"
                    android:layout_width="wrap_content" />
            </LinearLayout>
            """,
        "/work/shop/app/src/main/res/layout/other.xml": "<View android:id=\"@+id/cart_total_label\" />",
    ]

    private var resolver: AndroidSourceResolver {
        let files = self.files
        return AndroidSourceResolver(
            searchFiles: { name in files.keys.filter { ($0 as NSString).lastPathComponent == name } },
            readFile: { files[$0] },
            listDirectory: { directory in
                let prefix = directory.hasSuffix("/") ? directory : directory + "/"
                return Array(Set(files.keys.filter { $0.hasPrefix(prefix) }.compactMap {
                    $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
                }))
            }
        )
    }

    private func candidate(_ role: SourceCandidate.Role, _ name: String, _ package: String) -> SourceCandidate {
        SourceCandidate(
            role: role, className: name, moduleName: package, runtimeName: "\(package).\(name)",
            imagePath: "", imageUUID: nil, probes: []
        )
    }

    func test_classes_are_found_by_name_and_package_and_the_layout_by_id() async {
        let info = SourceInfo(
            className: "MaterialTextView", moduleName: "com.google.android.material.textview",
            dsymUUID: nil, guessedRelativePath: nil,
            candidates: [
                candidate(.viewController, "CartFragment", "com.example.shop.ui"),
                candidate(.viewController, "MainActivity", "com.example.shop"),
            ],
            platform: "android", resourceID: "cart_total", applicationID: "com.example.shop"
        )
        let lookup = await resolver.resolve(info)
        XCTAssertNil(lookup.note)
        XCTAssertEqual(lookup.locations.map(\.path), [
            // The layout that declares the id comes first for a stock widget…
            "/work/shop/app/src/main/res/layout/fragment_cart.xml",
            // …then the owners; the same file name in another package or in build output doesn't count.
            "/work/shop/app/src/main/java/com/example/shop/ui/CartFragment.kt",
            "/work/shop/app/src/main/java/com/example/shop/MainActivity.java",
        ])
        XCTAssertEqual(lookup.locations.map(\.line), [3, 6, 3])
        XCTAssertEqual(lookup.locations.map(\.role), [nil, .viewController, .viewController])
        XCTAssertFalse(lookup.isAmbiguous)
    }

    func test_an_app_defined_view_class_stays_ahead_of_the_layout() async {
        let info = SourceInfo(
            className: "CartFragment", moduleName: "com.example.shop.ui", dsymUUID: nil, guessedRelativePath: nil,
            candidates: [candidate(.viewClass, "CartFragment", "com.example.shop.ui")],
            platform: "android", resourceID: "cart_total"
        )
        let lookup = await resolver.resolve(info)
        XCTAssertEqual(lookup.locations.first?.role, .viewClass)
        XCTAssertEqual(lookup.locations.count, 2)
    }

    /// The sample app in this repository, searched the way Spotlight would
    /// be: by file name, anywhere under it.
    private func sampleResolver() -> AndroidSourceResolver {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SampleAppAndroid").path
        return AndroidSourceResolver(searchFiles: { name in
            (FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String } ?? [])
                .filter { ($0 as NSString).lastPathComponent == name }.map { "\(root)/\($0)" }
        })
    }

    func test_a_class_in_a_file_of_another_name_is_found_next_to_the_classes_around_it() async {
        // The sample's SampleBottomSheet is declared in DialogsFragment.kt.
        let info = SourceInfo(
            className: "TextView", moduleName: "android.widget", dsymUUID: nil, guessedRelativePath: nil,
            candidates: [
                candidate(.viewController, "SampleBottomSheet", "com.example.volysample.demo"),
                candidate(.viewController, "MainActivity", "com.example.volysample"),
            ],
            platform: "android", applicationID: "com.example.volysample"
        )
        let lookup = await sampleResolver().resolve(info)
        XCTAssertNil(lookup.note)
        XCTAssertEqual(lookup.locations.map { ($0.path as NSString).lastPathComponent }, ["DialogsFragment.kt", "MainActivity.kt"])
        XCTAssertEqual(lookup.locations.first?.className, "SampleBottomSheet")
        XCTAssertEqual(lookup.locations.first?.lineOrigin, .declaration)
        XCTAssertEqual(lookup.locations.first?.line, 43)
    }

    func test_with_no_class_found_by_name_the_apps_gradle_module_is_searched() async {
        let info = SourceInfo(
            className: "TextView", moduleName: "android.widget", dsymUUID: nil, guessedRelativePath: nil,
            candidates: [candidate(.viewController, "SampleBottomSheet", "com.example.volysample.demo")],
            platform: "android", applicationID: "com.example.volysample"
        )
        let lookup = await sampleResolver().resolve(info)
        XCTAssertEqual(lookup.locations.map { ($0.path as NSString).lastPathComponent }, ["DialogsFragment.kt"])

        // Another app's module is not this one's.
        let elsewhere = SourceInfo(
            className: "TextView", moduleName: "android.widget", dsymUUID: nil, guessedRelativePath: nil,
            candidates: [candidate(.viewController, "SampleBottomSheet", "com.example.volysample.demo")],
            platform: "android", applicationID: "com.example.other"
        )
        let none = await sampleResolver().resolve(elsewhere)
        XCTAssertTrue(none.locations.isEmpty)
    }

    func test_nothing_found_says_so() async {
        let info = SourceInfo(
            className: "TextView", moduleName: "android.widget", dsymUUID: nil, guessedRelativePath: nil,
            candidates: [candidate(.viewController, "CheckoutActivity", "com.example.shop")], platform: "android"
        )
        let lookup = await resolver.resolve(info)
        XCTAssertTrue(lookup.locations.isEmpty)
        XCTAssertEqual(lookup.note?.contains("CheckoutActivity"), true)

        let platformOnly = SourceInfo(
            className: "TextView", moduleName: "android.widget", dsymUUID: nil, guessedRelativePath: nil,
            candidates: [], platform: "android"
        )
        let none = await resolver.resolve(platformOnly)
        XCTAssertEqual(none.note?.contains("platform or library class"), true)
    }

    func test_the_navigator_sends_android_views_to_the_android_resolver() async {
        let files = self.files
        let navigator = VolySourceNavigator(
            fileExists: { files[$0] != nil },
            readFile: { files[$0] },
            searchFiles: { name in files.keys.filter { ($0 as NSString).lastPathComponent == name } }
        )
        let info = SourceInfo(
            className: "View", moduleName: "android.view", dsymUUID: nil, guessedRelativePath: nil,
            candidates: [candidate(.viewController, "MainActivity", "com.example.shop")], platform: "android"
        )
        let lookup = await navigator.resolve(info)
        XCTAssertEqual(lookup.locations.map(\.path), ["/work/shop/app/src/main/java/com/example/shop/MainActivity.java"])
        XCTAssertTrue(VolySourceNavigator.isAndroidSource("/a/Foo.kt"))
        XCTAssertTrue(VolySourceNavigator.isAndroidSource("/a/app/src/main/res/layout/x.xml"))
        XCTAssertFalse(VolySourceNavigator.isAndroidSource("/a/Info.xml"))
        XCTAssertFalse(VolySourceNavigator.isAndroidSource("/a/Foo.swift"))
    }

    func test_helpers() {
        XCTAssertEqual(AndroidSourceResolver.package(in: "// c\npackage  com.example.app;\nclass A"), "com.example.app")
        XCTAssertNil(AndroidSourceResolver.package(in: "class A"))
        XCTAssertEqual(AndroidSourceResolver.declarationLine(of: "Foo", in: "package a\n\nobject Foo {\n}"), 3)
        XCTAssertNil(AndroidSourceResolver.declarationLine(of: "Foo", in: "class FooBar"))
        XCTAssertEqual(
            AndroidSourceResolver.sourceSetsDirectory(of: "/p/app/src/main/kotlin/com/x/Foo.kt"), "/p/app/src"
        )
        XCTAssertNil(AndroidSourceResolver.sourceSetsDirectory(of: "/p/Foo.kt"))
    }
}

/// What an Android agent actually sends, decoded by the host's own types.
/// The samples are verbatim answers of the agent running in an emulator.
final class AndroidWireFormatTests: XCTestCase {
    private func response(_ json: String) throws -> Response {
        try Framing.decoder.decode(Response.self, from: Data(json.utf8))
    }

    func test_handshake_says_it_is_android() throws {
        let json = #"{"handshakeAccepted":{"_0":{"protocolVersion":1,"sessionID":"7DCC87DB-7C62-4BAF-AE72-1EEC60245614","agentName":"VolyAgent","agentVersion":"0.1.0","bundleIdentifier":"com.example.volysample","processName":"Voly Sample","pid":2728,"capabilities":{"injectionMode":"injected","previewHost":false,"localization":true,"screenshots":true,"navigation":true,"sourceSymbols":false},"platform":"android"}}}"#
        guard case .handshakeAccepted(let accepted) = try response(json) else { return XCTFail("not a handshake") }
        XCTAssertTrue(accepted.isAndroid)
        XCTAssertEqual(accepted.pid, 2728)
        XCTAssertNil(accepted.simulatorUDID)
        XCTAssertEqual(accepted.capabilities?.previewHost, false)
    }

    func test_an_ios_handshake_has_no_platform() throws {
        let json = #"{"handshakeAccepted":{"_0":{"protocolVersion":1,"sessionID":"7DCC87DB-7C62-4BAF-AE72-1EEC60245614","agentName":"VolyAgent","agentVersion":"0.1.0","processName":"SampleApp","pid":1,"simulatorUDID":"SIM-1"}}}"#
        guard case .handshakeAccepted(let accepted) = try response(json) else { return XCTFail("not a handshake") }
        XCTAssertFalse(accepted.isAndroid)
    }

    func test_constraints_made_from_layout_params_read_like_auto_layout_ones() throws {
        let json = #"{"constraints":{"_0":[{"id":24,"firstItemID":16,"firstAttribute":"leading","relation":"equal","secondItemID":15,"secondAttribute":"trailing","constant":12,"multiplier":1,"priority":1000,"identifier":"layout_constraintStart_toEndOf","isActive":true,"ownerID":13,"isSystemGenerated":false,"summary":"MaterialTextView.leading = AppCompatImageView.trailing × 1.0 + 12.0 @1000.0"},{"id":30,"firstItemID":16,"firstAttribute":"width","relation":"equal","secondAttribute":"notAnAttribute","constant":96,"multiplier":1,"priority":1000,"identifier":"layout_width","isActive":true,"ownerID":16,"isSystemGenerated":false,"summary":"MaterialTextView.width = nil.notAnAttribute × 1.0 + 96.0 @1000.0"}]}}"#
        guard case .constraints(let constraints) = try response(json) else { return XCTFail("not constraints") }
        let first = ConstraintPresentation(constraints[0])
        XCTAssertEqual(first.label, "Leading to")
        XCTAssertEqual(first.value, "AppCompatImageView.trailing + 12")
        let second = ConstraintPresentation(constraints[1])
        XCTAssertEqual(second.label, "Width equals")
        XCTAssertEqual(second.value, "96")
    }

    func test_source_info_and_errors() throws {
        let json = #"{"sourceInfo":{"_0":{"className":"MaterialTextView","moduleName":"com.google.android.material.textview","candidates":[{"role":"viewController","className":"ConstraintDemoFragment","moduleName":"com.example.volysample.demo","runtimeName":"com.example.volysample.demo.ConstraintDemoFragment","imagePath":"","probes":[]}],"platform":"android","resourceID":"constraint_name","applicationID":"com.example.volysample"}}}"#
        guard case .sourceInfo(let info) = try response(json) else { return XCTFail("not source info") }
        XCTAssertTrue(info.isAndroid)
        XCTAssertEqual(info.resourceID, "constraint_name")
        XCTAssertEqual(info.candidates?.first?.runtimeName, "com.example.volysample.demo.ConstraintDemoFragment")

        guard case .error(let error) = try response(#"{"error":{"_0":{"objectGone":{"_0":99999}}}}"#) else {
            return XCTFail("not an error")
        }
        XCTAssertEqual(error, .objectGone(99999))
        guard case .measureHoverResult(let other, let summary) = try response(
            #"{"measureHoverResult":{"otherID":21,"summary":{"kind":"sideBySide","vertical":325.09}}}"#
        ) else { return XCTFail("not a measurement") }
        XCTAssertEqual(other, 21)
        XCTAssertEqual(summary?.kind, .sideBySide)
        XCTAssertNil(summary?.horizontal)
    }
}

/// The MCP tools, talking about an Android app.
final class MCPToolboxAndroidTests: XCTestCase {
    private final class FakeAndroid: MCPInspecting, @unchecked Sendable {
        static let app = MCPApp(
            id: "android:emulator-5554:com.example.shop:4242", name: "Shop", bundleIdentifier: "com.example.shop",
            pid: 4242, simulatorUDID: "emulator-5554", simulatorName: "Pixel 8 API 35", isShownInVoly: false,
            platform: .android
        )
        static let device = MCPSimulator(
            udid: "emulator-5554", name: "Pixel 8 API 35", runtime: "Android 15 (API 35)",
            integration: "debuggable apps running here are inspectable", isIntegrationActive: true,
            appsWithoutAgent: ["com.example.release"], platform: .android
        )
        let answer: @Sendable (Command) throws -> Response
        private let lock = NSLock()
        private var displays: [String] = []

        init(_ answer: @escaping @Sendable (Command) throws -> Response) { self.answer = answer }

        var capturedDisplays: [String] {
            lock.lock()
            defer { lock.unlock() }
            return displays
        }

        var access: MCPAccess { get async { .full } }
        func apps() async -> [MCPApp] { [Self.app] }
        func overview() async -> MCPOverview { MCPOverview(simulators: [Self.device], apps: [Self.app]) }
        func send(_ command: Command, to appID: String) async throws -> Response { try answer(command) }
        func selection() async -> (appID: String, viewID: ObjectID)? { nil }
        func select(view: ObjectID, in appID: String) async throws {}
        func appDidChange(_ appID: String) async {}
        func relaunch(bundleIdentifier: String, simulatorUDID: String) async throws {}
        func noteToolCall(_ name: String) async {}
        func captureDisplay(of app: MCPApp) async throws -> Data? {
            note(app.simulatorUDID ?? "?")
            return AndroidFixtures.onePixelPNG
        }

        private func note(_ serial: String) {
            lock.lock()
            defer { lock.unlock() }
            displays.append(serial)
        }
    }

    private static func screen(root: ViewDescription) -> ScreenDescription {
        ScreenDescription(
            appName: "Shop", bundleIdentifier: "com.example.shop", screenSize: CGSizeCodable(width: 393, height: 851),
            scale: 2.75, orientation: .portrait, appearance: "light", contentSizeCategory: "1x",
            topViewController: "CartFragment", roots: [root], viewCount: 1, isTruncated: false
        )
    }

    private static var label: ViewDescription {
        var node = ViewDescription(
            id: 7, className: "MaterialTextView", frame: CGRectCodable(x: 16, y: 120, width: 200, height: 20),
            isHidden: false, alpha: 1, clipsToBounds: false
        )
        node.text = "Total"
        node.accessibilityIdentifier = "cart_total"
        node.font = "sans-serif Regular 14sp"
        return node
    }

    func test_list_apps_names_android_devices_as_such() async {
        let toolbox = MCPToolbox(inspector: FakeAndroid { _ in .screenDescription(Self.screen(root: Self.label)) })
        let text = await toolbox.call("list_apps", arguments: .object([:]))?.text ?? ""
        XCTAssertTrue(text.contains("No iOS simulator is booted."))
        XCTAssertTrue(text.contains("Android emulators and devices:"))
        XCTAssertTrue(text.contains("- Pixel 8 API 35, Android 15 (API 35) (emulator-5554): debuggable apps running here are inspectable"))
        XCTAssertTrue(text.contains("com.example.release — Voly can only inspect debuggable (debug) builds on Android"))
        XCTAssertTrue(text.contains("- Shop  bundle=com.example.shop  pid=4242  android=Pixel 8 API 35"))
    }

    func test_get_screen_speaks_dp_and_compose() async {
        let toolbox = MCPToolbox(inspector: FakeAndroid { _ in .screenDescription(Self.screen(root: Self.label)) })
        let text = await toolbox.call("get_screen", arguments: .object([:]))?.text ?? ""
        XCTAssertTrue(text.contains("Shop (com.example.shop) in Pixel 8 API 35"))
        XCTAssertTrue(text.contains("Screen 393×851 dp @2.8x, portrait, light mode, font scale 1x. Top screen: CartFragment."))
        XCTAssertTrue(text.contains("how Jetpack Compose content appears"))
        XCTAssertFalse(text.contains("SwiftUI"))
        XCTAssertTrue(text.contains(#"MaterialTextView #7 16,120 200×20 "Total" font=sans-serif Regular 14sp id=cart_total"#))
    }

    func test_get_view_uses_the_agents_own_layout_summary() async {
        var root = Self.label
        root.layout = LayoutDetails(
            bounds: CGRectCodable(x: 0, y: 0, width: 200, height: 20), usesAutoLayout: true,
            intrinsicWidth: nil, intrinsicHeight: nil, huggingHorizontal: 0, huggingVertical: 0,
            compressionResistanceHorizontal: 0, compressionResistanceVertical: 0,
            safeAreaInsets: .zero, layoutMargins: .zero,
            summary: "child of ConstraintLayout; layout_width=wrap_content layout_height=wrap_content"
        )
        let described = root
        let toolbox = MCPToolbox(inspector: FakeAndroid { command in
            switch command {
            case .describeScreen: return .screenDescription(Self.screen(root: described))
            case .getConstraints: return .constraints([])
            case .getProperties: return .properties(PropertyBag(objectID: 7, view: [:], layer: [:], custom: []))
            default: return .ack
            }
        })
        let text = await toolbox.call("get_view", arguments: ["view": 7, "source": false])?.text ?? ""
        XCTAssertTrue(text.contains("Layout: child of ConstraintLayout; layout_width=wrap_content layout_height=wrap_content"))
        XCTAssertFalse(text.contains("hugging"))
        XCTAssertTrue(text.contains("Constraints: none (no fixed size, margin or ConstraintLayout connection)."))
    }

    func test_the_whole_display_is_captured_through_the_inspector() async {
        let inspector = FakeAndroid { command in
            if case .screenInfo = command { return .screenInfo(ScreenInfo(orientation: .landscapeLeft, scale: 2.75)) }
            return .ack
        }
        let result = await MCPToolbox(
            inspector: inspector,
            captureSimulator: { _ in
                XCTFail("simctl must not be asked about an Android device")
                return Data()
            }
        ).call("screenshot", arguments: ["target": "simulator"])
        XCTAssertEqual(inspector.capturedDisplays, ["emulator-5554"])
        XCTAssertEqual(result?.isError, false)
        XCTAssertTrue(result?.text.contains("the whole display of Pixel 8 API 35") ?? false)
        XCTAssertTrue(result?.text.contains("1 dp = ") ?? false)
    }

    func test_preferences_from_several_files_say_which_file() async {
        let items = [
            UserDefaultsItem(suite: "com.example.shop_preferences", key: "counter", type: .int, value: .int(3)),
            UserDefaultsItem(suite: "settings", key: "theme", type: .string, value: .string("dark")),
        ]
        let toolbox = MCPToolbox(inspector: FakeAndroid { _ in .userDefaults(items) })
        let text = await toolbox.call("get_user_defaults", arguments: .object([:]))?.text ?? ""
        XCTAssertTrue(text.contains("com.example.shop_preferences/counter (int) = 3"))
        XCTAssertTrue(text.contains(#"settings/theme (string) = "dark""#))
        let set = await toolbox.call("set_user_default", arguments: ["key": "counter", "value": 4])?.text ?? ""
        XCTAssertEqual(set, "Set counter = 4 in Shop's SharedPreferences.")
    }

    func test_app_ids_are_stable_handles() {
        let endpoint = AndroidAgentEndpoint(
            serial: "emulator-5554", package: "com.example.shop", pid: 4242, label: "Shop", port: 40123, token: "t"
        )
        XCTAssertEqual(AndroidMCP.appID(endpoint), "android:emulator-5554:com.example.shop:4242")
        let app = AndroidMCP.app(endpoint, deviceName: "Pixel 8 API 35", isShownInVoly: true)
        XCTAssertEqual(app.platform, .android)
        XCTAssertEqual(app.simulatorUDID, "emulator-5554")
        let status = AndroidDeviceStatus(
            device: AndroidFixtures.pixel, isIntegrationEnabled: true,
            apps: [
                AndroidAppStatus(package: "com.example.shop", pid: 4242, state: .inspectable),
                AndroidAppStatus(package: "com.example.release", pid: 5, state: .notDebuggable),
                AndroidAppStatus(package: "com.example.skipped", pid: 6, state: .excluded),
            ],
            error: nil
        )
        let simulator = AndroidMCP.simulator(status)
        XCTAssertEqual(simulator.platform, .android)
        XCTAssertEqual(simulator.runtime, "Android 15 (API 35)")
        XCTAssertEqual(simulator.appsWithoutAgent, ["com.example.release"])
    }
}
