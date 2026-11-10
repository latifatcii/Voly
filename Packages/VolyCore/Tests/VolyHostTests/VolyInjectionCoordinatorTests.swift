import XCTest
@testable import VolyHost

final class VolyInjectionCoordinatorTests: XCTestCase {
    /// Records every launchctl call made through `simctl spawn` and lets a
    /// test stand in for what the simulator would do in response.
    final class SimulatorShell: ShellExecutor, @unchecked Sendable {
        var invocations: [[String]] = []
        /// Exit code per launchctl verb + service target, default 0.
        var failures: [String: Int32] = [:]
        var onKickstart: (() -> Void)?

        func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
            invocations.append(arguments)
            // ["simctl", "spawn", udid, "launchctl", verb, ...]
            let verb = arguments[4]
            let target = arguments.first { $0.hasSuffix("com.apple.runningboardd") } ?? ""
            let code = failures["\(verb) \(target)"] ?? 0
            if verb == "kickstart", code == 0 { onKickstart?() }
            return ShellResult(exitCode: code, stdout: Data(), stderr: Data((code == 0 ? "" : "boom").utf8))
        }

        func launchctlCalls() -> [[String]] { invocations.map { Array($0.dropFirst(4)) } }
    }

    private var support: URL!
    private let udid = "SIM-1"
    private let runtime = StagedRuntime(agentPath: "/staged/VolyAgent.dylib", bridgePath: "/staged/VolyLaunchBridge.dylib")
    /// pids the fake "simulator" currently runs a runningboardd under.
    private let live = LivePIDs()

    final class LivePIDs: @unchecked Sendable {
        var pids: Set<Int32> = []
    }

    override func setUp() {
        super.setUp()
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("voly-coordinator-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
        super.tearDown()
    }

    private func makeCoordinator(_ shell: SimulatorShell) -> VolyInjectionCoordinator {
        let live = self.live
        return VolyInjectionCoordinator(
            supportDirectory: support,
            shell: shell,
            isBridgeHostAlive: { live.pids.contains($0) },
            pollInterval: .milliseconds(5),
            loadTimeout: .milliseconds(150)
        )
    }

    /// What the bridge does when it loads: announce itself.
    private func writeStatus(
        _ coordinator: VolyInjectionCoordinator,
        pid: Int32,
        hookInstalled: Bool = true,
        failureReason: String? = nil,
        udid: String? = nil
    ) throws {
        var status: [String: Any] = [
            "bridgeVersion": "1",
            "pid": Int(pid),
            "hookInstalled": hookInstalled,
            "simulatorUDID": udid ?? self.udid,
            "loadedAt": Date(),
            "runtimeVersion": "18.3.1",
        ]
        if let failureReason { status["failureReason"] = failureReason }
        let url = coordinator.statusURL(forSimulator: self.udid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: status, format: .xml, options: 0).write(to: url)
        live.pids.insert(pid)
    }

    // MARK: - state

    func test_state_is_inactive_without_a_status_file() {
        XCTAssertEqual(makeCoordinator(SimulatorShell()).state(forSimulator: udid), .inactive)
    }

    func test_state_is_inactive_when_the_announcing_runningboardd_is_gone() throws {
        let coordinator = makeCoordinator(SimulatorShell())
        try writeStatus(coordinator, pid: 100)
        live.pids = []   // simulator rebooted
        XCTAssertEqual(coordinator.state(forSimulator: udid), .inactive)
    }

    func test_state_ignores_a_status_written_for_another_simulator() throws {
        let coordinator = makeCoordinator(SimulatorShell())
        try writeStatus(coordinator, pid: 100, udid: "OTHER")
        XCTAssertEqual(coordinator.state(forSimulator: udid), .inactive)
    }

    func test_state_follows_the_config_switch_while_the_bridge_is_loaded() throws {
        let coordinator = makeCoordinator(SimulatorShell())
        try writeStatus(coordinator, pid: 100)
        var config = BridgeConfig(enabled: true, simulatorUDID: udid, agentPath: "/a", policy: .init())
        try config.write(to: coordinator.configURL(forSimulator: udid))
        XCTAssertTrue(coordinator.state(forSimulator: udid).isActive)

        config.enabled = false
        try config.write(to: coordinator.configURL(forSimulator: udid))
        guard case .paused = coordinator.state(forSimulator: udid) else {
            return XCTFail("expected paused")
        }
    }

    func test_state_reports_a_runtime_the_bridge_could_not_hook() throws {
        let coordinator = makeCoordinator(SimulatorShell())
        try writeStatus(coordinator, pid: 100, hookInstalled: false, failureReason: "RBLaunchdJobManager class not found")
        guard case .unsupported(let reason, _) = coordinator.state(forSimulator: udid) else {
            return XCTFail("expected unsupported")
        }
        XCTAssertEqual(reason, "RBLaunchdJobManager class not found")
    }

    // MARK: - enable

    func test_enable_arms_runningboardd_only_then_restarts_it() async throws {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        shell.onKickstart = { try? self.writeStatus(coordinator, pid: 200) }

        let state = try await coordinator.enable(simulator: udid, runtime: runtime, policy: .init())

        XCTAssertTrue(state.isActive)
        let configPath = coordinator.configURL(forSimulator: udid).path
        XCTAssertEqual(shell.launchctlCalls(), [
            ["debug", "user/foreground/com.apple.runningboardd", "--environment",
             "DYLD_INSERT_LIBRARIES=/staged/VolyLaunchBridge.dylib", "VOLY_BRIDGE_CONFIG=\(configPath)"],
            ["kickstart", "-k", "user/foreground/com.apple.runningboardd"],
        ])
        // Every call is scoped to this one simulator.
        XCTAssertTrue(shell.invocations.allSatisfy { Array($0.prefix(3)) == ["simctl", "spawn", udid] })
        let config = try XCTUnwrap(BridgeConfig.read(from: coordinator.configURL(forSimulator: udid)))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.agentPath, "/staged/VolyAgent.dylib")
        XCTAssertEqual(config.simulatorUDID, udid)
    }

    func test_enable_falls_back_to_the_system_domain_on_older_runtimes() async throws {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        shell.failures["debug user/foreground/com.apple.runningboardd"] = 113
        shell.onKickstart = { try? self.writeStatus(coordinator, pid: 200) }

        _ = try await coordinator.enable(simulator: udid, runtime: runtime, policy: .init())

        let verbsAndTargets = shell.launchctlCalls().map { call in
            "\(call[0]) \(call.first { $0.hasSuffix("runningboardd") } ?? "")"
        }
        XCTAssertEqual(verbsAndTargets, [
            "debug user/foreground/com.apple.runningboardd",
            "debug system/com.apple.runningboardd",
            // …and the restart goes to the spelling that worked.
            "kickstart system/com.apple.runningboardd",
        ])
    }

    func test_enable_does_not_restart_anything_when_the_bridge_is_already_loaded() async throws {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        try writeStatus(coordinator, pid: 100)
        try BridgeConfig(enabled: false, simulatorUDID: udid, agentPath: "/old", policy: .init())
            .write(to: coordinator.configURL(forSimulator: udid))

        let state = try await coordinator.enable(simulator: udid, runtime: runtime, policy: .init())

        XCTAssertTrue(state.isActive)
        XCTAssertTrue(shell.invocations.isEmpty)
    }

    func test_enable_fails_and_cleans_up_when_the_bridge_never_announces_itself() async {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        do {
            _ = try await coordinator.enable(simulator: udid, runtime: runtime, policy: .init())
            XCTFail("expected bridgeDidNotLoad")
        } catch {
            XCTAssertEqual(error as? VolyInjectionCoordinator.CoordinatorError, .bridgeDidNotLoad)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.directory(forSimulator: udid).path))
    }

    func test_enable_retries_once_when_a_booting_simulator_swallows_the_first_restart() async throws {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        var kickstarts = 0
        shell.onKickstart = {
            kickstarts += 1
            // First restart: the service doesn't come back in time. Second: it does.
            if kickstarts == 2 { try? self.writeStatus(coordinator, pid: 300) }
        }

        let state = try await coordinator.enable(simulator: udid, runtime: runtime, policy: .init())

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(shell.launchctlCalls().map(\.first), ["debug", "kickstart", "debug", "kickstart"])
        XCTAssertEqual(BridgeConfig.read(from: coordinator.configURL(forSimulator: udid))?.enabled, true)
    }

    func test_enable_backs_out_of_a_runtime_the_bridge_cannot_hook() async {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        var kickstarts = 0
        shell.onKickstart = {
            kickstarts += 1
            if kickstarts == 1 {
                try? self.writeStatus(coordinator, pid: 200, hookInstalled: false, failureReason: "unexpected launch signature")
            } else {
                self.live.pids = [201]   // restarted without the bridge
            }
        }
        do {
            _ = try await coordinator.enable(simulator: udid, runtime: runtime, policy: .init())
            XCTFail("expected unsupportedRuntime")
        } catch {
            XCTAssertEqual(
                error as? VolyInjectionCoordinator.CoordinatorError,
                .unsupportedRuntime("unexpected launch signature")
            )
        }
        // The bridge was taken back out and nothing is left configured.
        XCTAssertEqual(kickstarts, 2)
        XCTAssertEqual(coordinator.state(forSimulator: udid), .inactive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.directory(forSimulator: udid).path))
    }

    func test_enable_surfaces_a_launchctl_failure() async {
        let shell = SimulatorShell()
        shell.failures["debug user/foreground/com.apple.runningboardd"] = 1
        shell.failures["debug system/com.apple.runningboardd"] = 1
        do {
            _ = try await makeCoordinator(shell).enable(simulator: udid, runtime: runtime, policy: .init())
            XCTFail("expected launchctlFailed")
        } catch {
            XCTAssertEqual(
                error as? VolyInjectionCoordinator.CoordinatorError,
                .launchctlFailed(step: "debug", code: 1, output: "boom")
            )
        }
    }

    // MARK: - disable / policy / cleanup

    func test_disable_switches_off_unloads_and_removes_every_file() async throws {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        try writeStatus(coordinator, pid: 100)
        let configURL = coordinator.configURL(forSimulator: udid)
        try BridgeConfig(enabled: true, simulatorUDID: udid, agentPath: "/a", policy: .init()).write(to: configURL)
        var enabledAtRestart: Bool?
        shell.onKickstart = {
            enabledAtRestart = BridgeConfig.read(from: configURL)?.enabled
            self.live.pids = [101]   // fresh runningboardd, no bridge
        }

        try await coordinator.disable(simulator: udid)

        // The switch is flipped before the restart, so a failed restart
        // still leaves the loaded bridge inert.
        XCTAssertEqual(enabledAtRestart, false)
        XCTAssertEqual(shell.launchctlCalls(), [["kickstart", "-k", "user/foreground/com.apple.runningboardd"]])
        XCTAssertEqual(coordinator.state(forSimulator: udid), .inactive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.directory(forSimulator: udid).path))
    }

    func test_disable_restarts_again_if_a_pending_debug_config_reloaded_the_bridge() async throws {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        try writeStatus(coordinator, pid: 100)
        var kickstarts = 0
        shell.onKickstart = {
            kickstarts += 1
            if kickstarts == 1 {
                self.live.pids = []
                try? self.writeStatus(coordinator, pid: 101)   // armed config consumed: bridge is back
            } else {
                self.live.pids = [102]
            }
        }
        try await coordinator.disable(simulator: udid)
        XCTAssertEqual(kickstarts, 2)
        XCTAssertEqual(coordinator.state(forSimulator: udid), .inactive)
    }

    func test_disable_without_a_loaded_bridge_touches_nothing_in_the_simulator() async throws {
        let shell = SimulatorShell()
        let coordinator = makeCoordinator(shell)
        try BridgeConfig(enabled: true, simulatorUDID: udid, agentPath: "/a", policy: .init())
            .write(to: coordinator.configURL(forSimulator: udid))
        try await coordinator.disable(simulator: udid)
        XCTAssertTrue(shell.invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.directory(forSimulator: udid).path))
    }

    func test_updatePolicy_rewrites_only_the_policy() throws {
        let coordinator = makeCoordinator(SimulatorShell())
        let url = coordinator.configURL(forSimulator: udid)
        try BridgeConfig(enabled: true, simulatorUDID: udid, agentPath: "/a", policy: .init()).write(to: url)

        try coordinator.updatePolicy(
            simulator: udid,
            policy: InjectionPolicy(includeSystemApps: true, allowedBundleIDs: ["com.a"], excludedBundleIDs: ["com.b"])
        )

        let config = try XCTUnwrap(BridgeConfig.read(from: url))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.agentPath, "/a")
        XCTAssertEqual(config.policy, InjectionPolicy(includeSystemApps: true, allowedBundleIDs: ["com.a"], excludedBundleIDs: ["com.b"]))
    }

    func test_adopt_repoints_every_simulator_at_the_newly_staged_agent() throws {
        let coordinator = makeCoordinator(SimulatorShell())
        for id in ["A", "B"] {
            try BridgeConfig(enabled: true, simulatorUDID: id, agentPath: "/old/VolyAgent.dylib", policy: .init())
                .write(to: coordinator.configURL(forSimulator: id))
        }
        coordinator.adopt(runtime: runtime)
        for id in ["A", "B"] {
            XCTAssertEqual(BridgeConfig.read(from: coordinator.configURL(forSimulator: id))?.agentPath, "/staged/VolyAgent.dylib")
        }
    }

    func test_removeStaleState_drops_dead_simulators_but_not_ones_being_enabled() throws {
        let coordinator = makeCoordinator(SimulatorShell())
        try writeStatus(coordinator, pid: 100)   // live bridge for `udid`
        for id in ["REBOOTED", "ENABLING"] {
            try BridgeConfig(enabled: true, simulatorUDID: id, agentPath: "/a", policy: .init())
                .write(to: coordinator.configURL(forSimulator: id))
        }
        try BridgeConfig(enabled: true, simulatorUDID: udid, agentPath: "/a", policy: .init())
            .write(to: coordinator.configURL(forSimulator: udid))

        let removed = coordinator.removeStaleState(excluding: ["ENABLING"])

        XCTAssertEqual(removed, ["REBOOTED"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.configURL(forSimulator: "ENABLING").path))
        XCTAssertTrue(coordinator.state(forSimulator: udid).isActive)
    }
}
