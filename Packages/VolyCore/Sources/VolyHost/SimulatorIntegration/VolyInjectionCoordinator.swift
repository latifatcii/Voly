import Darwin
import Foundation
import OSLog

private let log = Logger(subsystem: "com.latifatci.Voly", category: "InjectionCoordinator")

/// Turns simulator-wide runtime integration on and off for one simulator.
///
/// "On" means `VolyLaunchBridge.dylib` is loaded in that simulator's
/// runningboardd and appends the agent to every eligible app launch — see
/// `LaunchBridge/VolyLaunchBridge.m`. The only thing changed inside the
/// simulator is a one-shot `launchctl debug` environment for runningboardd;
/// it is consumed by the restart we trigger and is gone after the next one,
/// so a simulator reboot always returns to stock behaviour.
///
/// Restarting the simulator's runningboardd does not terminate running apps.
/// Apps that were already running simply stay un-instrumented until their
/// next launch; this type never relaunches anything.
public struct VolyInjectionCoordinator: Sendable {
    public enum State: Equatable, Sendable {
        /// The bridge is not loaded in this simulator.
        case inactive
        /// Loaded and adding the agent to new app launches.
        case active(BridgeStatus)
        /// Loaded but switched off by config; launches are untouched.
        case paused(BridgeStatus)
        /// Loaded, but this runtime doesn't have the launch seam the bridge
        /// needs. Nothing is hooked and launches are untouched.
        case unsupported(reason: String, BridgeStatus)

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }
    }

    public enum CoordinatorError: Error, Equatable, LocalizedError {
        case launchctlFailed(step: String, code: Int32, output: String)
        case bridgeDidNotLoad
        case unsupportedRuntime(String)

        public var errorDescription: String? {
            switch self {
            case .launchctlFailed(let step, let code, let output):
                return "Simulator launchctl \(step) failed (\(code)): \(output)"
            case .bridgeDidNotLoad:
                return "The simulator's launch service restarted but Voly's launch bridge did not load."
            case .unsupportedRuntime(let reason):
                return "This simulator runtime isn't supported by Voly's launch bridge: \(reason)"
            }
        }
    }

    /// launchd service that owns app launches inside a simulator. Newer
    /// runtimes want the `user/foreground` domain and accept `system` only
    /// with a warning; older ones only know `system`.
    static let serviceTargets = [
        "user/foreground/com.apple.runningboardd",
        "system/com.apple.runningboardd",
    ]
    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    public let supportDirectory: URL
    private let shell: ShellExecutor
    private let isBridgeHostAlive: @Sendable (Int32) -> Bool
    private let pollInterval: Duration
    private let loadTimeout: Duration

    /// - Parameter isBridgeHostAlive: whether `pid` is a live runningboardd.
    public init(
        supportDirectory: URL,
        shell: ShellExecutor = SystemShellExecutor(),
        isBridgeHostAlive: @escaping @Sendable (Int32) -> Bool = VolyInjectionCoordinator.isLiveRunningBoard,
        pollInterval: Duration = .milliseconds(100),
        loadTimeout: Duration = .seconds(12)
    ) {
        self.supportDirectory = supportDirectory
        self.shell = shell
        self.isBridgeHostAlive = isBridgeHostAlive
        self.pollInterval = pollInterval
        self.loadTimeout = loadTimeout
    }

    /// Overrides where Voly keeps its state (tests run a scratch Voly
    /// beside a real one).
    public static let supportDirectoryEnvironmentKey = "VOLY_SUPPORT_DIRECTORY"

    public static var defaultSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[supportDirectoryEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Voly", isDirectory: true)
    }

    // MARK: - Paths

    public func directory(forSimulator udid: String) -> URL {
        supportDirectory
            .appendingPathComponent("Simulators", isDirectory: true)
            .appendingPathComponent(udid, isDirectory: true)
    }

    public func configURL(forSimulator udid: String) -> URL {
        directory(forSimulator: udid).appendingPathComponent(BridgeConfig.fileName)
    }

    func statusURL(forSimulator udid: String) -> URL {
        directory(forSimulator: udid).appendingPathComponent(BridgeStatus.fileName)
    }

    // MARK: - State

    /// Cheap (two small file reads and a pid probe); safe to call on a timer.
    public func state(forSimulator udid: String) -> State {
        guard let status = BridgeStatus.read(from: statusURL(forSimulator: udid)),
              status.simulatorUDID == udid,
              isBridgeHostAlive(status.pid)
        else { return .inactive }
        guard status.hookInstalled else {
            return .unsupported(reason: status.failureReason ?? "launch hook unavailable", status)
        }
        let enabled = BridgeConfig.read(from: configURL(forSimulator: udid))?.enabled ?? false
        return enabled ? .active(status) : .paused(status)
    }

    /// Simulators with leftover Voly files but no live bridge — e.g. after a
    /// simulator reboot or a Voly crash. Their files are removed so a stale
    /// status can never be mistaken for a loaded bridge.
    ///
    /// - Parameter excluding: simulators mid-`enable`, whose config exists
    ///   before their bridge has announced itself.
    @discardableResult
    public func removeStaleState(excluding: Set<String> = []) -> [String] {
        let root = supportDirectory.appendingPathComponent("Simulators", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var removed: [String] = []
        for entry in entries {
            let udid = entry.lastPathComponent
            if !excluding.contains(udid), state(forSimulator: udid) == .inactive {
                try? FileManager.default.removeItem(at: entry)
                removed.append(udid)
            }
        }
        if !removed.isEmpty {
            log.notice("removed stale integration state for \(removed.joined(separator: ", "), privacy: .public)")
        }
        return removed
    }

    // MARK: - Enable

    /// Load the bridge into `udid`'s runningboardd (once) and switch it on.
    /// Only affects apps launched from now on.
    @discardableResult
    public func enable(simulator udid: String, runtime: StagedRuntime, policy: InjectionPolicy) async throws -> State {
        let config = BridgeConfig(enabled: true, simulatorUDID: udid, agentPath: runtime.agentPath, policy: policy)
        try config.write(to: configURL(forSimulator: udid))
        adopt(runtime: runtime)

        switch state(forSimulator: udid) {
        case .active, .paused:
            // Already loaded; the bridge re-reads the config on next launch.
            log.notice("integration re-enabled for \(udid, privacy: .public) (bridge already loaded)")
            return state(forSimulator: udid)
        case .unsupported(let reason, _):
            throw CoordinatorError.unsupportedRuntime(reason)
        case .inactive:
            break
        }

        // A simulator that is still booting can take the restart but not
        // bring the service back in time; one clean retry covers that.
        var lastError = CoordinatorError.bridgeDidNotLoad
        for attempt in 1...Self.loadAttempts {
            do {
                return try await loadBridge(into: udid, runtime: runtime, config: config)
            } catch let error as CoordinatorError where error == .bridgeDidNotLoad && attempt < Self.loadAttempts {
                lastError = error
                log.notice("bridge did not load in \(udid, privacy: .public) (attempt \(attempt)); retrying")
                try? await Task.sleep(for: pollInterval * 10)
            }
        }
        throw lastError
    }

    private static let loadAttempts = 2

    /// Arm runningboardd's next launch with the bridge, restart it, and wait
    /// for the bridge to announce itself. Leaves nothing armed on failure.
    private func loadBridge(into udid: String, runtime: StagedRuntime, config: BridgeConfig) async throws -> State {
        try config.write(to: configURL(forSimulator: udid))
        try? FileManager.default.removeItem(at: statusURL(forSimulator: udid))
        let environment = [
            "DYLD_INSERT_LIBRARIES=\(runtime.bridgePath)",
            "VOLY_BRIDGE_CONFIG=\(configURL(forSimulator: udid).path)",
        ]
        let target = try await launchctl(udid, step: "debug") { ["debug", $0, "--environment"] + environment }
        log.notice("bridge armed for \(udid, privacy: .public); restarting simulator launch service")
        _ = try await launchctl(udid, step: "kickstart", preferring: target) { ["kickstart", "-k", $0] }

        let deadline = ContinuousClock.now + loadTimeout
        while ContinuousClock.now < deadline {
            switch state(forSimulator: udid) {
            case .active(let status):
                log.notice("bridge active in \(udid, privacy: .public) (runningboardd pid \(status.pid), iOS \(status.runtimeVersion ?? "?", privacy: .public))")
                return .active(status)
            case .unsupported(let reason, _):
                // The bridge loaded but refused to hook. Get it back out so
                // the simulator runs a stock launch service.
                log.error("bridge unsupported on \(udid, privacy: .public): \(reason, privacy: .public)")
                try? await disable(simulator: udid)
                throw CoordinatorError.unsupportedRuntime(reason)
            case .paused, .inactive:
                try? await Task.sleep(for: pollInterval)
            }
        }
        // Leave no armed-but-unverified configuration behind.
        try? await disable(simulator: udid)
        throw CoordinatorError.bridgeDidNotLoad
    }

    /// Rewrite the policy for a simulator whose bridge is loaded. No restart;
    /// applies to the next app launch.
    public func updatePolicy(simulator udid: String, policy: InjectionPolicy) throws {
        let url = configURL(forSimulator: udid)
        guard var config = BridgeConfig.read(from: url) else { return }
        config.includeSystemApps = policy.includeSystemApps
        config.allowedBundleIDs = policy.allowedBundleIDs
        config.excludedBundleIDs = policy.excludedBundleIDs
        try config.write(to: url)
    }

    /// Point every simulator's bridge config at a (re)staged agent.
    ///
    /// A new Voly build stages its dylibs under a new content hash and the
    /// old copy is pruned, while bridges loaded by the previous build are
    /// still running. They re-read their config per launch, so rewriting the
    /// path is all it takes for them to hand out the new agent.
    public func adopt(runtime: StagedRuntime) {
        let root = supportDirectory.appendingPathComponent("Simulators", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            let url = entry.appendingPathComponent(BridgeConfig.fileName)
            guard var config = BridgeConfig.read(from: url), config.agentPath != runtime.agentPath else { continue }
            config.agentPath = runtime.agentPath
            do {
                try config.write(to: url)
                log.notice("bridge config for \(config.simulatorUDID, privacy: .public) now points at the newly staged agent")
            } catch {
                log.error("could not update agent path for \(config.simulatorUDID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Disable

    /// Switch the bridge off and unload it by restarting the launch service
    /// without it. Running apps keep running (with their agent, if they had
    /// one) and new launches are stock again.
    public func disable(simulator udid: String) async throws {
        let configURL = configURL(forSimulator: udid)
        // Flip the switch first: even if the restart below fails, the loaded
        // bridge stops touching launches from this point on.
        if var config = BridgeConfig.read(from: configURL) {
            config.enabled = false
            try? config.write(to: configURL)
        }

        // An armed `launchctl debug` that was never consumed would reload
        // the bridge on the first restart, so allow one more round.
        for _ in 0..<2 {
            guard let status = BridgeStatus.read(from: statusURL(forSimulator: udid)),
                  isBridgeHostAlive(status.pid)
            else { break }
            _ = try await launchctl(udid, step: "kickstart") { ["kickstart", "-k", $0] }
            let deadline = ContinuousClock.now + loadTimeout
            while isBridgeHostAlive(status.pid), ContinuousClock.now < deadline {
                try? await Task.sleep(for: pollInterval)
            }
            // Give a bridge that got reloaded a moment to announce itself.
            try? await Task.sleep(for: pollInterval * 3)
        }
        try? FileManager.default.removeItem(at: directory(forSimulator: udid))
        log.notice("integration disabled for \(udid, privacy: .public)")
    }

    // MARK: - launchctl

    /// Run `launchctl` inside the simulator against runningboardd, trying
    /// each known service-target spelling. Returns the one that worked.
    private func launchctl(
        _ udid: String,
        step: String,
        preferring preferred: String? = nil,
        arguments: (String) -> [String]
    ) async throws -> String {
        var targets = Self.serviceTargets
        if let preferred, let index = targets.firstIndex(of: preferred) {
            targets.swapAt(0, index)
        }
        var lastFailure = CoordinatorError.launchctlFailed(step: step, code: -1, output: "")
        for target in targets {
            let result = try await shell.run(
                executable: Self.xcrun,
                arguments: ["simctl", "spawn", udid, "launchctl"] + arguments(target),
                environment: nil
            )
            if result.exitCode == 0 { return target }
            let output = [result.stderr, result.stdout]
                .compactMap { String(data: $0, encoding: .utf8) }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastFailure = .launchctlFailed(step: step, code: result.exitCode, output: output)
        }
        throw lastFailure
    }

    /// `pid` exists and its executable is a simulator runningboardd.
    public static func isLiveRunningBoard(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
            .hasSuffix("/usr/libexec/runningboardd")
    }
}
