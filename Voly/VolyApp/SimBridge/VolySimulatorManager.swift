import Foundation
import Observation
import OSLog
import VolyHost

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "SimulatorManager")

/// Tracks booted simulators and owns per-simulator runtime integration.
///
/// By default every booted simulator gets integration, so an app can be
/// inspected without switching anything on first; single simulators can be
/// opted out, or "all" turned off in favour of a hand-picked set (see
/// `IntegrationPreference`). Integration loads Voly's launch bridge into a
/// simulator (see `VolyInjectionCoordinator`); apps launched afterwards —
/// from Xcode, SpringBoard or `simctl` — come up with the agent already
/// loaded and their debugger untouched. Nothing here ever terminates an app
/// on its own: `relaunch` is the one explicit exception.
@MainActor
@Observable
final class VolySimulatorManager {
    struct RunningAppEntry: Identifiable, Equatable {
        let bundleIdentifier: String
        let pid: Int32
        /// An agent in this exact process has announced itself.
        let isInstrumented: Bool
        /// The bridge will add the agent the next time this app launches.
        let instrumentsOnNextLaunch: Bool
        var id: String { "\(bundleIdentifier):\(pid)" }
    }

    struct Simulator: Identifiable, Equatable {
        let device: SimDevice
        var integration: VolyInjectionCoordinator.State
        var runningApps: [RunningAppEntry]
        var isBusy: Bool
        var error: String?

        var id: String { device.udid }

        /// `com.apple.CoreSimulator.SimRuntime.iOS-18-3` → `iOS 18.3`
        var runtimeName: String {
            let tail = device.runtime.split(separator: ".").last.map(String.init) ?? device.runtime
            let parts = tail.split(separator: "-")
            guard let platform = parts.first else { return tail }
            return "\(platform) \(parts.dropFirst().joined(separator: "."))"
        }
    }

    private static let policyKey = "voly.integration.policy"

    private(set) var simulators: [Simulator] = []
    /// Shown when simulator discovery itself fails (e.g. no Xcode selected).
    private(set) var discoveryError: String?
    /// Set when Voly's simulator dylibs couldn't be staged; integration
    /// can't be enabled until that is fixed.
    private(set) var stagingError: String?
    private(set) var policy: InjectionPolicy

    /// Listing running apps costs a `simctl spawn` per simulator, so it only
    /// happens while the inspector is on screen.
    var isInspectorVisible = false

    private let inventory = SimInventory()
    private let runningApps = RunningAppsLocator()
    private let portFiles = PortFileWatcher()
    private let launcher = SimctlLauncher()
    private let coordinator = VolyInjectionCoordinator(
        supportDirectory: VolyInjectionCoordinator.defaultSupportDirectory
    )
    private let stager = VolyRuntimeStager(supportDirectory: VolyInjectionCoordinator.defaultSupportDirectory)
    private var stagedRuntime: StagedRuntime?

    /// Which simulators should have integration. The bridge itself only
    /// lives until a simulator shuts down (or Voly quits), so this is what
    /// applies it to every simulator that boots.
    private(set) var preference: IntegrationPreference
    private var busyUDIDs: Set<String> = []
    private var errors: [String: String] = [:]
    /// Restore attempts per booted simulator, so a runtime that can't be
    /// hooked isn't retried forever while a slow boot still gets another go.
    private var restoreAttempts: [String: Int] = [:]
    private static let maxRestoreAttempts = 3
    private var timer: Timer?
    private var refreshInFlight = false

    init() {
        let defaults = UserDefaults.standard
        preference = IntegrationPreference(defaults: defaults)
        if let data = defaults.data(forKey: Self.policyKey),
           let stored = try? JSONDecoder().decode(InjectionPolicy.self, from: data) {
            policy = stored
        } else {
            policy = InjectionPolicy()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.removeLegacySessionWideInjection()
            // Stage up front so simulators whose bridge is still loaded from
            // a previous run of Voly hand out this build's agent.
            do {
                _ = try self.stageRuntime()
            } catch {
                self.stagingError = error.localizedDescription
                log.error("staging simulator runtime failed: \(error.localizedDescription, privacy: .public)")
            }
            await self.refresh()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Older Voly builds set `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` for the
    /// whole login session. Take that back; integration is per simulator now.
    private func removeLegacySessionWideInjection() async {
        let legacy = AutoAttachInstaller(bundledDylibPath: Self.bundledURL(VolyRuntimeStager.agentFileName).path)
        if (try? await legacy.removeLegacyInstall()) == true {
            log.notice("removed legacy session-wide SIMCTL_CHILD_DYLD_INSERT_LIBRARIES")
        }
    }

    // MARK: - Discovery

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        let devices: [SimDevice]
        do {
            devices = try await inventory.listDevices(bootedOnly: true)
            discoveryError = nil
        } catch {
            discoveryError = "Could not list simulators: \(error.localizedDescription)"
            log.error("simulator discovery failed: \(String(describing: error), privacy: .public)")
            return
        }
        let booted = Set(devices.map(\.udid))
        let appeared = booted.subtracting(simulators.map(\.id))
        let vanished = Set(simulators.map(\.id)).subtracting(booted)
        if !appeared.isEmpty { log.notice("simulators booted: \(appeared.sorted().joined(separator: ", "), privacy: .public)") }
        if !vanished.isEmpty { log.notice("simulators shut down: \(vanished.sorted().joined(separator: ", "), privacy: .public)") }

        // A shut-down simulator took its bridge with it; drop its leftovers.
        coordinator.removeStaleState(excluding: busyUDIDs)
        // Count attempts per loss of the bridge: a simulator that went away,
        // or one whose bridge is back, starts from zero next time.
        restoreAttempts = restoreAttempts.filter {
            booted.contains($0.key) && !coordinator.state(forSimulator: $0.key).isActive
        }
        errors = errors.filter { booted.contains($0.key) }

        var updated: [Simulator] = []
        for device in devices {
            let integration = coordinator.state(forSimulator: device.udid)
            var apps: [RunningAppEntry] = []
            if isInspectorVisible {
                let instrumented = Set(portFiles.scan(deviceUDIDs: [device.udid]).map(\.pid))
                let running = (try? await runningApps.listRunningUserApps(deviceUDID: device.udid)) ?? []
                apps = running.map { app in
                    RunningAppEntry(
                        bundleIdentifier: app.bundleIdentifier,
                        pid: app.pid,
                        isInstrumented: instrumented.contains(app.pid),
                        instrumentsOnNextLaunch: integration.isActive
                            && policy.allows(bundleIdentifier: app.bundleIdentifier)
                    )
                }
            } else if let previous = simulators.first(where: { $0.id == device.udid }) {
                apps = previous.runningApps
            }
            updated.append(Simulator(
                device: device,
                integration: integration,
                runningApps: apps,
                isBusy: busyUDIDs.contains(device.udid),
                error: errors[device.udid]
            ))
        }
        if updated != simulators { simulators = updated }

        // A bridge loaded in a simulator that shouldn't have one — opted out,
        // or left over from a crash in hand-picked mode — is removed rather
        // than left as an unexplained modification.
        for simulator in updated where simulator.integration != .inactive
            && !preference.wants(simulator.id)
            && !simulator.isBusy {
            log.notice("launch bridge loaded in \(simulator.id, privacy: .public) but not wanted there; removing it")
            await applyIntegration(enabled: false, to: simulator.id)
        }

        // Bring integration up wherever it is wanted: by default that is
        // every booted simulator, including ones that boot later.
        for simulator in updated where preference.wants(simulator.id)
            && simulator.integration == .inactive
            && !simulator.isBusy
            && restoreAttempts[simulator.id, default: 0] < Self.maxRestoreAttempts {
            restoreAttempts[simulator.id, default: 0] += 1
            log.notice("enabling integration on \(simulator.id, privacy: .public) (attempt \(self.restoreAttempts[simulator.id] ?? 0))")
            await applyIntegration(enabled: true, to: simulator.id)
        }
    }

    // MARK: - Integration

    func isIntegrationWanted(for udid: String) -> Bool { preference.wants(udid) }

    /// Switch between "every booted simulator" and a hand-picked set. What
    /// is integrated at this moment doesn't change; only what happens to
    /// simulators from here on.
    func setIntegratesAllSimulators(_ all: Bool) async {
        let active = Set(simulators.filter(\.integration.isActive).map(\.id))
        preference.setAllSimulators(all, currentlyActive: active)
        preference.save(to: .standard)
        restoreAttempts.removeAll()
        log.notice("integration mode: \(all ? "all booted simulators" : "selected simulators only", privacy: .public)")
        await refresh()
    }

    /// The per-simulator switch: remember the choice, then act on it.
    func setIntegration(enabled: Bool, for udid: String) async {
        preference.set(enabled, for: udid)
        preference.save(to: .standard)
        restoreAttempts[udid] = nil
        await applyIntegration(enabled: enabled, to: udid)
    }

    /// Load or unload the bridge without touching the stored preference —
    /// used directly when bringing a simulator in line with it.
    private func applyIntegration(enabled: Bool, to udid: String) async {
        guard busyUDIDs.insert(udid).inserted else { return }
        errors[udid] = nil
        markBusy(udid, true)
        defer {
            busyUDIDs.remove(udid)
            markBusy(udid, false)
        }
        do {
            if enabled {
                let runtime = try stageRuntime()
                try await coordinator.enable(simulator: udid, runtime: runtime, policy: policy)
                log.notice("integration enabled for \(udid, privacy: .public)")
            } else {
                try await coordinator.disable(simulator: udid)
                log.notice("integration disabled for \(udid, privacy: .public)")
            }
        } catch {
            errors[udid] = error.localizedDescription
            log.error("integration \(enabled ? "enable" : "disable", privacy: .public) failed for \(udid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        refreshState(of: udid)
    }

    /// Quit path: take the bridge out of every simulator so nothing of Voly
    /// keeps running in them while Voly isn't. The per-simulator choice is
    /// kept and re-applied on the next launch.
    ///
    /// Returns the work instead of doing it, because AppKit is tearing the
    /// main run loop down at that point: the caller runs it off the main
    /// actor and waits for it.
    func prepareUnloadForQuit() -> @Sendable () async -> Void {
        timer?.invalidate()
        timer = nil
        let coordinator = self.coordinator
        let loaded = simulators.filter { $0.integration != .inactive }.map(\.id)
        return {
            for udid in loaded {
                do {
                    try await coordinator.disable(simulator: udid)
                    log.notice("unloaded launch bridge from \(udid, privacy: .public) on quit")
                } catch {
                    log.error("could not unload launch bridge from \(udid, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func stageRuntime() throws -> StagedRuntime {
        if let stagedRuntime { return stagedRuntime }
        let runtime = try stager.stage(
            bundledAgent: Self.bundledURL(VolyRuntimeStager.agentFileName),
            bundledBridge: Self.bundledURL(VolyRuntimeStager.bridgeFileName)
        )
        stagedRuntime = runtime
        stagingError = nil
        // Bridges loaded by an earlier Voly build keep working: repoint them.
        coordinator.adopt(runtime: runtime)
        return runtime
    }

    /// The simulator dylibs embedded by the Voly target's "Embed Simulator
    /// Dylibs" build phase.
    private static func bundledURL(_ name: String) -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)")
    }

    private func markBusy(_ udid: String, _ busy: Bool) {
        guard let index = simulators.firstIndex(where: { $0.id == udid }) else { return }
        simulators[index].isBusy = busy
    }

    private func refreshState(of udid: String) {
        guard let index = simulators.firstIndex(where: { $0.id == udid }) else { return }
        simulators[index].integration = coordinator.state(forSimulator: udid)
        simulators[index].error = errors[udid]
    }

    // MARK: - Policy

    func setExcluded(_ excluded: Bool, bundleIdentifier: String) {
        var updated = policy
        updated.excludedBundleIDs.removeAll { $0 == bundleIdentifier }
        if excluded { updated.excludedBundleIDs.append(bundleIdentifier) }
        apply(updated)
    }

    /// A non-empty allow list restricts instrumentation to exactly those apps.
    func setAllowListed(_ listed: Bool, bundleIdentifier: String) {
        var updated = policy
        updated.allowedBundleIDs.removeAll { $0 == bundleIdentifier }
        if listed { updated.allowedBundleIDs.append(bundleIdentifier) }
        apply(updated)
    }

    func clearAllowList() {
        var updated = policy
        updated.allowedBundleIDs = []
        apply(updated)
    }

    private func apply(_ updated: InjectionPolicy) {
        policy = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.policyKey)
        }
        // Loaded bridges pick the new policy up on the next app launch.
        for simulator in simulators where simulator.integration != .inactive {
            do {
                try coordinator.updatePolicy(simulator: simulator.id, policy: updated)
            } catch {
                errors[simulator.id] = error.localizedDescription
            }
        }
        log.notice("injection policy updated: \(updated.excludedBundleIDs.count) excluded, \(updated.allowedBundleIDs.count) allow-listed")
    }

    // MARK: - Explicit relaunch

    /// Terminate and relaunch one app with the agent. Only ever called from
    /// a user action that says so — this ends that app's debug session.
    func relaunch(bundleIdentifier: String, on udid: String) async throws {
        let runtime = try stageRuntime()
        log.notice("user-requested relaunch of \(bundleIdentifier, privacy: .public) on \(udid, privacy: .public)")
        _ = try await launcher.launch(
            deviceUDID: udid,
            bundleIdentifier: bundleIdentifier,
            dylibPath: URL(fileURLWithPath: runtime.agentPath)
        )
    }
}
