import XCTest
@testable import VolyHost

final class BridgeConfigTests: XCTestCase {
    func test_plist_uses_exactly_the_keys_the_launch_bridge_reads() throws {
        // LaunchBridge/VolyLaunchBridge.m reads these keys by name; renaming
        // a Swift property must not silently disable the bridge.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voly-bridge-config-\(UUID().uuidString)/bridge.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let policy = InjectionPolicy(includeSystemApps: true, allowedBundleIDs: ["com.a"], excludedBundleIDs: ["com.b"])
        try BridgeConfig(enabled: true, simulatorUDID: "SIM", agentPath: "/x/VolyAgent.dylib", policy: policy).write(to: url)

        let raw = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(Set(raw.keys), [
            "version", "enabled", "simulatorUDID", "agentPath",
            "includeSystemApps", "allowedBundleIDs", "excludedBundleIDs",
        ])
        XCTAssertEqual(raw["enabled"] as? Bool, true)
        XCTAssertEqual(raw["simulatorUDID"] as? String, "SIM")
        XCTAssertEqual(raw["agentPath"] as? String, "/x/VolyAgent.dylib")
        XCTAssertEqual(raw["allowedBundleIDs"] as? [String], ["com.a"])
        XCTAssertEqual(raw["excludedBundleIDs"] as? [String], ["com.b"])
        XCTAssertEqual(BridgeConfig.read(from: url)?.policy, policy)
    }

    func test_default_policy_instruments_developer_apps_only() {
        let policy = InjectionPolicy()
        XCTAssertTrue(policy.allows(bundleIdentifier: "com.example.MyApp"))
        XCTAssertFalse(policy.allows(bundleIdentifier: "com.apple.mobilesafari"))
    }

    func test_exclusion_wins_over_everything() {
        let policy = InjectionPolicy(
            includeSystemApps: true, allowedBundleIDs: ["com.example.MyApp"], excludedBundleIDs: ["com.example.MyApp"]
        )
        XCTAssertFalse(policy.allows(bundleIdentifier: "com.example.MyApp"))
    }

    func test_allow_list_restricts_to_the_listed_apps() {
        let policy = InjectionPolicy(allowedBundleIDs: ["com.example.One", "com.apple.Preferences"])
        XCTAssertTrue(policy.allows(bundleIdentifier: "com.example.One"))
        // Explicitly listing a system app opts it in.
        XCTAssertTrue(policy.allows(bundleIdentifier: "com.apple.Preferences"))
        XCTAssertFalse(policy.allows(bundleIdentifier: "com.example.Two"))
    }

    func test_include_system_apps() {
        XCTAssertTrue(InjectionPolicy(includeSystemApps: true).allows(bundleIdentifier: "com.apple.mobilesafari"))
    }
}

final class VolyRuntimeStagerTests: XCTestCase {
    private var root: URL!
    private var bundled: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voly-stager-tests-\(UUID().uuidString)")
        bundled = root.appendingPathComponent("Voly.app/Contents/Resources")
        try? FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func writeBundled(agent: String, bridge: String) throws -> (URL, URL) {
        let agentURL = bundled.appendingPathComponent(VolyRuntimeStager.agentFileName)
        let bridgeURL = bundled.appendingPathComponent(VolyRuntimeStager.bridgeFileName)
        try Data(agent.utf8).write(to: agentURL)
        try Data(bridge.utf8).write(to: bridgeURL)
        return (agentURL, bridgeURL)
    }

    func test_stage_copies_out_of_the_bundle_and_is_stable_for_identical_content() throws {
        let stager = VolyRuntimeStager(supportDirectory: root.appendingPathComponent("support"))
        let (agent, bridge) = try writeBundled(agent: "agent-v1", bridge: "bridge-v1")

        let first = try stager.stage(bundledAgent: agent, bundledBridge: bridge)
        let second = try stager.stage(bundledAgent: agent, bundledBridge: bridge)

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.agentPath.hasPrefix(bundled.path))
        XCTAssertEqual(try String(contentsOfFile: first.agentPath, encoding: .utf8), "agent-v1")
        XCTAssertEqual(try String(contentsOfFile: first.bridgePath, encoding: .utf8), "bridge-v1")
        XCTAssertTrue(first.agentPath.hasSuffix("/VolyAgent.dylib"))
        XCTAssertTrue(first.bridgePath.hasSuffix("/VolyLaunchBridge.dylib"))
    }

    func test_a_rebuilt_dylib_gets_a_new_path_and_never_rewrites_the_old_one() throws {
        let stager = VolyRuntimeStager(supportDirectory: root.appendingPathComponent("support"))
        var (agent, bridge) = try writeBundled(agent: "agent-v1", bridge: "bridge-v1")
        let old = try stager.stage(bundledAgent: agent, bundledBridge: bridge)
        // A process that mapped the old copy holds it open across the update.
        let mapped = try FileHandle(forReadingFrom: URL(fileURLWithPath: old.agentPath))
        defer { try? mapped.close() }

        (agent, bridge) = try writeBundled(agent: "agent-v2", bridge: "bridge-v1")
        let new = try stager.stage(bundledAgent: agent, bundledBridge: bridge)

        XCTAssertNotEqual(new.agentPath, old.agentPath)
        XCTAssertEqual(try String(contentsOfFile: new.agentPath, encoding: .utf8), "agent-v2")
        // Old copy is unlinked, not overwritten: what was mapped is unchanged.
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.agentPath))
        XCTAssertEqual(String(decoding: try XCTUnwrap(mapped.readToEnd()), as: UTF8.self), "agent-v1")
    }

    func test_stage_reports_a_missing_bundled_dylib() throws {
        let stager = VolyRuntimeStager(supportDirectory: root.appendingPathComponent("support"))
        let missing = bundled.appendingPathComponent("VolyAgent.dylib")
        XCTAssertThrowsError(try stager.stage(bundledAgent: missing, bundledBridge: missing)) { error in
            XCTAssertEqual(error as? VolyRuntimeStager.StagingError, .missingBundledDylib(missing.path))
        }
    }
}
