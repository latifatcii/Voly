import Foundation
import Observation
import OSLog
import VolyHost

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "AndroidDevices")

/// Tracks Android emulators (and devices adb can reach) and keeps the Voly
/// agent attached to the debuggable apps running on them.
///
/// The Android side of `VolySimulatorManager`, and much smaller: an agent
/// can be attached to an app that is already running, so there is nothing
/// to install into the system and no app is ever relaunched for it.
///
/// It stays out of the way of anyone who doesn't use Android: nothing
/// happens unless `adb` is installed, and adb is only talked to while its
/// server is already running — Voly never starts one.
@MainActor
@Observable
final class AndroidDeviceManager {
    private static let disabledKey = "voly.android.disabledDevices"

    /// Devices, their running apps, and the agents that can be connected to.
    private(set) var snapshot = AndroidSnapshot.empty
    /// Why Android support can't work in this build (the agent is missing
    /// from the bundle). Only shown when there is a device to use it on.
    private(set) var setupError: String?
    /// Devices a switch was just flipped for.
    private(set) var busySerials: Set<String> = []

    /// Called with the full list whenever the reachable agents change.
    var onAgentsChanged: (([AndroidAgentEndpoint]) -> Void)?
    /// The app exclusions shared with simulator integration.
    var policyProvider: () -> InjectionPolicy = { InjectionPolicy() }

    private var disabledSerials: Set<String>
    private var integration: AndroidIntegration?
    private var adbURL: URL?
    private var lastAdbLookup = Date.distantPast
    private var timer: Timer?
    private var refreshInFlight = false
    private var lastAgents: [AndroidAgentEndpoint] = []

    init(defaults: UserDefaults = .standard) {
        disabledSerials = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    #if DEBUG
    /// UI previews only: show these devices without touching adb.
    func setPreview(snapshot: AndroidSnapshot) {
        self.snapshot = snapshot
    }
    #endif

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        Task { @MainActor [weak self] in await self?.refresh() }
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Quit path: give the forwarded ports back. Returned as work to run off
    /// the main actor, like the simulator manager's unload.
    func prepareReleaseForQuit() -> @Sendable () async -> Void {
        timer?.invalidate()
        timer = nil
        let integration = self.integration
        return { await integration?.releaseAll() }
    }

    // MARK: - Discovery

    /// A refresh whose result the caller is going to read: waits out one
    /// that is already running.
    func refreshAndWait() async {
        for _ in 0..<200 where refreshInFlight {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await refresh()
    }

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        guard let integration = await currentIntegration() else {
            publish(.empty)
            return
        }
        let disabled = disabledSerials
        // Only the exclusions carry over: an "instrument only these apps"
        // list made of iOS bundle identifiers must not shut every Android
        // app out.
        let excluded = Set(policyProvider().excludedBundleIDs)
        var only: Set<String>?
        #if DEBUG
        // A scripted run touches the simulators it was given and nothing else.
        only = ScriptedRun.simulators
        #endif
        let fresh = await integration.refresh(
            wantsDevice: { !disabled.contains($0) },
            allowsApp: { !excluded.contains($0) },
            only: only
        )
        publish(fresh)
    }

    private func publish(_ fresh: AndroidSnapshot) {
        if fresh != snapshot { snapshot = fresh }
        if fresh.agents != lastAgents {
            lastAgents = fresh.agents
            onAgentsChanged?(fresh.agents)
        }
    }

    /// The integration, once there is something for it to talk to: adb is
    /// installed, its server is running, and the agent is in the bundle.
    private func currentIntegration() async -> AndroidIntegration? {
        if adbURL == nil, Date().timeIntervalSince(lastAdbLookup) > 30 {
            lastAdbLookup = Date()
            adbURL = await Task.detached { AdbLocator.locate() }.value
            if let adbURL { log.notice("adb found at \(adbURL.path, privacy: .public)") }
        }
        guard let adbURL else { return nil }
        guard await Task.detached(operation: { AdbServerProbe.isRunning() }).value else { return nil }
        if let integration { return integration }
        do {
            let payload = try AndroidAgentPayload.load(from: AndroidAgentPayload.bundledDirectories())
            let created = AndroidIntegration(adb: AdbClient(executable: adbURL), payload: payload)
            integration = created
            setupError = nil
            log.notice("Android agent \(payload.version, privacy: .public) ready")
            return created
        } catch {
            if setupError == nil {
                log.error("Android support unavailable: \(error.localizedDescription, privacy: .public)")
            }
            setupError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Per-device switch

    func isEnabled(_ serial: String) -> Bool {
        !disabledSerials.contains(serial)
    }

    func setEnabled(_ enabled: Bool, for serial: String) async {
        if enabled { disabledSerials.remove(serial) } else { disabledSerials.insert(serial) }
        UserDefaults.standard.set(disabledSerials.sorted(), forKey: Self.disabledKey)
        log.notice("Android integration \(enabled ? "on" : "off", privacy: .public) for \(serial, privacy: .public)")
        busySerials.insert(serial)
        defer { busySerials.remove(serial) }
        if enabled { await integration?.retryFailures(serial: serial) }
        await refreshAndWait()
    }

    /// Try again for apps where attaching failed.
    func retry(serial: String) async {
        busySerials.insert(serial)
        defer { busySerials.remove(serial) }
        await integration?.retryFailures(serial: serial)
        await refreshAndWait()
    }

    // MARK: - Lookups

    func device(serial: String) -> AndroidDevice? {
        snapshot.devices.first { $0.device.serial == serial }?.device
    }

    func isAndroidDevice(_ identifier: String) -> Bool {
        device(serial: identifier) != nil
    }

    // MARK: - Things done on request

    /// Stop the app and start it again. Only ever from a user action.
    func relaunch(package: String, on serial: String) async throws {
        guard let integration else { throw AdbError.notFound }
        log.notice("user-requested relaunch of \(package, privacy: .public) on \(serial, privacy: .public)")
        try await integration.relaunch(serial: serial, package: package)
        await refreshAndWait()
    }

    /// PNG of the whole display, system UI included.
    func screenshot(serial: String) async throws -> Data {
        guard let integration else { throw AdbError.notFound }
        return try await integration.screenshot(serial: serial)
    }
}
