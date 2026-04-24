import AppKit
import Foundation
import Observation
import VolyHost
import OSLog

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "AppCoordinator")

@MainActor
final class AppCoordinator {
    private let session: InspectorSession
    private let window: InspectorWindowController
    private let menuBar: MenuBarController
    private let attachment: SimulatorAttachment
    private let locator: SimulatorLocator
    private let autoAttach: AutoAttachInstaller
    private let runningApps = RunningAppsLocator()
    private let launcher = SimctlLauncher()
    private let inventory = SimInventory()
    private let portFileWatcher = PortFileWatcher()
    private var hotkey: GlobalHotkey?
    private var attachmentObservation: Task<Void, Never>?
    private var toggleInFlight = false
    private var attachInFlight = false
    /// Cooldown per bundle id — don't rip-relaunch the same app faster than this.
    private static let autoReattachCooldown: TimeInterval = 5
    private var autoReattachTimer: Timer?
    private var lastReattachAttempt: [String: Date] = [:]

    init(session: InspectorSession) {
        self.session = session
        self.window = InspectorWindowController(session: session)
        let locator = AXSimulatorLocator()
        self.locator = locator
        self.attachment = SimulatorAttachment(
            locator: locator,
            scheduler: TimerAttachmentScheduler(),
            voly: .voly,
            screenProvider: Self.screen(for:)
        )
        self.autoAttach = AutoAttachInstaller(
            bundledDylibPath: Self.bundledDylibPath()
        )
        self.menuBar = MenuBarController(
            onToggle: {}, onQuit: {}, onAbout: {}, onToggleAutoAttach: {}, onAttachRunningApp: {}
        )

        wireCallbacks()
    }

    /// Resolves `Voly.app/Contents/Resources/VolyAgent.dylib`. The dylib is
    /// embedded by the Voly target's "Embed VolyAgent.dylib" run-script
    /// phase — its absence is a programmer error.
    private static func bundledDylibPath() -> String {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/VolyAgent.dylib")
        return url.path
    }

    /// Return the visible frame of the screen that contains the Simulator,
    /// or the main screen if none matches. Keeps attachment correct on
    /// multi-display setups.
    private static func screen(for simulatorFrame: CGRect?) -> CGRect {
        let screens = NSScreen.screens
        if let sim = simulatorFrame,
           let match = screens.first(where: { $0.frame.intersects(sim) }) {
            return match.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame ?? .zero
    }

    func start() {
        hotkey = GlobalHotkey(
            keyCode: HotkeyDefaults.keyCode,
            modifiers: HotkeyDefaults.modifiers
        ) { [weak self] in
            self?.toggleInspector()
        }
        if hotkey == nil {
            log.warning("Global hotkey registration failed; menu-bar icon still toggles Voly.")
        }

        // Auto-attach install + nudge + reflect state in menu bar. Fire-and-
        // forget; failures log but don't block the rest of startup.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.installAutoAttachOnStart()
        }
    }

    func toggleInspector() {
        if window.isVisible {
            hideInspector()
        } else {
            showInspector()
        }
    }

    func showInspector() {
        attachment.start()
        let simFrame = locator.frontmostSimulatorFrame()
        let seed = AttachmentCalculator.attach(
            simulatorFrame: simFrame,
            voly: .voly,
            screen: Self.screen(for: simFrame)
        )
        window.show(at: seed.frame)
        menuBar.isInspectorVisible = true
        startObservingAttachment()
    }

    func hideInspector() {
        exitInteractiveModes()
        attachment.stop()
        window.hide()
        menuBar.isInspectorVisible = false
        stopObservingAttachment()
    }

    /// Ensure Pick mode can't stay active while Voly is hidden or closed —
    /// otherwise the on-simulator overlay window and the Mac-side global
    /// NSEvent monitor would keep running with no way for the user to toggle
    /// them off.
    private func exitInteractiveModes() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.session.state.pickModeActive {
                await self.session.exitPickMode()
            }
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// Flip between enabled and disabled. Called from the menu bar item.
    /// Serialized by `toggleInFlight` so a rapid double-click can't
    /// interleave two shell dispatches.
    func toggleAutoAttach() {
        guard !toggleInFlight else { return }
        toggleInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.toggleInFlight = false }
            guard let self else { return }
            do {
                let current = try await self.autoAttach.currentState()
                switch current {
                case .enabled:
                    try await self.autoAttach.uninstall()
                    StaleProcessNudge.resetEpoch()
                    self.stopAutoReattachPolling()
                case .disabled, .foreign:
                    try await self.autoAttach.ensureInstalled()
                    StaleProcessNudge.runIfNeeded()
                    self.startAutoReattachPolling()
                }
                await self.refreshAutoAttachMenuState()
            } catch {
                log.error("toggleAutoAttach failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Install if needed, then refresh the menu bar + nudge on startup.
    /// Called once from `start()`.
    private func installAutoAttachOnStart() async {
        do {
            try await autoAttach.ensureInstalled()
            await refreshAutoAttachMenuState()
            let state = try await autoAttach.currentState()
            if case .enabled = state {
                StaleProcessNudge.runIfNeeded()
                startAutoReattachPolling()
            }
        } catch {
            log.error("autoAttach install on start failed: \(String(describing: error), privacy: .public)")
            menuBar.isAutoAttachEnabled = false
        }
    }

    // MARK: - Auto-reattach poll
    //
    // Xcode's debug launch (⌘R) speaks directly to CoreSimulator's XPC service
    // and doesn't inherit `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, so our
    // launchctl-based auto-attach is a no-op for Xcode-launched apps. This
    // timer closes that gap: if a user app is running in the booted sim but
    // doesn't have a Voly port file, relaunch it via simctl (with the env
    // var) so the dylib gets injected. Kills the Xcode debug session —
    // expected tradeoff; user can toggle auto-attach off for debug sessions.

    private func startAutoReattachPolling() {
        guard autoReattachTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollAndReattach()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoReattachTimer = timer
        log.notice("auto-reattach polling started")
    }

    private func stopAutoReattachPolling() {
        autoReattachTimer?.invalidate()
        autoReattachTimer = nil
        lastReattachAttempt.removeAll(keepingCapacity: true)
        log.notice("auto-reattach polling stopped")
    }

    private func pollAndReattach() async {
        guard menuBar.isAutoAttachEnabled else { return }
        let dylibURL = URL(fileURLWithPath: Self.bundledDylibPath())
        do {
            let devices = try await inventory.listDevices(bootedOnly: true)
            guard let device = devices.first else { return }
            let running = try await runningApps.listRunningUserApps(deviceUDID: device.udid)
            guard !running.isEmpty else { return }
            let attached = portFileWatcher.scan(deviceUDIDs: [device.udid])
            let attachedPids = Set(attached.map(\.pid))
            let now = Date()
            for app in running where !attachedPids.contains(app.pid) {
                if let last = lastReattachAttempt[app.bundleIdentifier],
                   now.timeIntervalSince(last) < Self.autoReattachCooldown {
                    continue
                }
                lastReattachAttempt[app.bundleIdentifier] = now
                log.notice("auto-reattach: \(app.bundleIdentifier, privacy: .public) (pid=\(app.pid)) unattached — relaunching via simctl")
                _ = try? await launcher.launch(
                    deviceUDID: device.udid,
                    bundleIdentifier: app.bundleIdentifier,
                    dylibPath: dylibURL
                )
            }
        } catch {
            log.info("auto-reattach poll failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Read current installer state and reflect it into the menu bar
    /// checkmark. Swallows errors (menu just shows Off in that case).
    private func refreshAutoAttachMenuState() async {
        do {
            let state = try await autoAttach.currentState()
            if case .enabled = state {
                menuBar.isAutoAttachEnabled = true
            } else {
                menuBar.isAutoAttachEnabled = false
            }
        } catch {
            log.error("autoAttach state refresh failed: \(String(describing: error), privacy: .public)")
            menuBar.isAutoAttachEnabled = false
        }
    }

    private func wireCallbacks() {
        window.onClose = { [weak self] in
            self?.exitInteractiveModes()
            self?.menuBar.isInspectorVisible = false
            self?.attachment.stop()
            self?.stopObservingAttachment()
        }
        menuBar.onToggle = { [weak self] in self?.toggleInspector() }
        menuBar.onQuit = { [weak self] in self?.quit() }
        menuBar.onAbout = { NSApp.orderFrontStandardAboutPanel(nil) }
        menuBar.onToggleAutoAttach = { [weak self] in self?.toggleAutoAttach() }
        menuBar.onAttachRunningApp = { [weak self] in self?.attachRunningApp() }
    }

    /// Find the user's running sim app and relaunch it via direct simctl with
    /// SIMCTL_CHILD_DYLD_INSERT_LIBRARIES set to VolyAgent.dylib. Xcode's debug
    /// launch replaces DYLD_INSERT_LIBRARIES wholesale and ignores our
    /// launchctl setenv value, so we need this manual re-launch path.
    func attachRunningApp() {
        guard !attachInFlight else { return }
        attachInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.attachInFlight = false }
            guard let self else { return }
            do {
                let devices = try await self.inventory.listDevices(bootedOnly: true)
                guard let device = devices.first else {
                    self.showAlert(
                        title: "No booted simulator",
                        info: "Boot a simulator and launch your app, then try again."
                    )
                    return
                }
                let apps = try await self.runningApps.listRunningUserApps(deviceUDID: device.udid)
                guard let target = apps.first else {
                    self.showAlert(
                        title: "No running app found",
                        info: "Run your app in the simulator, then try Attach again."
                    )
                    return
                }
                log.notice("relaunching \(target.bundleIdentifier, privacy: .public) with VolyAgent injected")
                _ = try await self.launcher.launch(
                    deviceUDID: device.udid,
                    bundleIdentifier: target.bundleIdentifier,
                    dylibPath: URL(fileURLWithPath: Self.bundledDylibPath())
                )
            } catch {
                log.error("attachRunningApp failed: \(String(describing: error), privacy: .public)")
                self.showAlert(
                    title: "Attach failed",
                    info: error.localizedDescription
                )
            }
        }
    }

    private func showAlert(title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startObservingAttachment() {
        stopObservingAttachment()
        attachmentObservation = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self?.attachment.currentResult
                    } onChange: {
                        cont.resume()
                    }
                }
                guard let self else { return }
                guard let result = self.attachment.currentResult,
                      result.edge != .detached,
                      !self.window.userHasDetached
                else { continue }
                // animated: false — live-tracking ticks at 15 Hz; AppKit's
                // implicit animation would lag the cadence and race with the
                // isProgrammaticMove flag reset, wrongly marking the window
                // as user-detached mid-animation.
                self.window.setFrame(result.frame, animated: false)
            }
        }
    }

    private func stopObservingAttachment() {
        attachmentObservation?.cancel()
        attachmentObservation = nil
    }
}
