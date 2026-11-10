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
    private var simulators: VolySimulatorManager { session.simulators }
    private var hotkey: GlobalHotkey?
    private var simulatorHotkey: FrontmostAppHotkey?
    private var attachmentObservation: Task<Void, Never>?
    private var relaunchInFlight = false

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
        self.menuBar = MenuBarController(
            onToggle: {}, onQuit: {}, onAbout: {}, onRelaunchRunningApp: {}
        )

        wireCallbacks()
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
        // ⌘E next to the Simulator. Scoped, so ⌘E elsewhere is untouched.
        var scopedApps: Set<String> = [HotkeyDefaults.simulatorBundleIdentifier]
        if let own = Bundle.main.bundleIdentifier { scopedApps.insert(own) }
        simulatorHotkey = FrontmostAppHotkey(
            keyCode: HotkeyDefaults.simulatorKeyCode,
            modifiers: HotkeyDefaults.simulatorModifiers,
            whileFrontmost: scopedApps
        ) { [weak self] in
            self?.toggleInspector()
        }

        // Simulator discovery + restoring per-simulator runtime integration
        // the user had turned on. Fire-and-forget; failures surface in the
        // simulator list, they don't block the rest of startup.
        simulators.start()
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
        simulators.isInspectorVisible = true
        Task { @MainActor [weak self] in await self?.simulators.refresh() }
        startObservingAttachment()
    }

    func hideInspector() {
        exitInteractiveModes()
        attachment.stop()
        window.hide()
        menuBar.isInspectorVisible = false
        simulators.isInspectorVisible = false
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

    private func wireCallbacks() {
        window.onClose = { [weak self] in
            self?.exitInteractiveModes()
            self?.menuBar.isInspectorVisible = false
            self?.simulators.isInspectorVisible = false
            self?.attachment.stop()
            self?.stopObservingAttachment()
        }
        menuBar.onToggle = { [weak self] in self?.toggleInspector() }
        // ⌘E typed into the inspector itself (it can be key while another
        // app is frontmost, where the scoped hotkey isn't registered).
        window.onToggleShortcut = { [weak self] in self?.toggleInspector() }
        menuBar.onQuit = { [weak self] in self?.quit() }
        menuBar.onAbout = { NSApp.orderFrontStandardAboutPanel(nil) }
        menuBar.onRelaunchRunningApp = { [weak self] in self?.relaunchRunningApp() }
        menuBar.simulatorsProvider = { [weak self] in self?.simulators.simulators ?? [] }
        menuBar.onSetIntegration = { [weak self] udid, enabled in
            self?.setIntegration(enabled: enabled, for: udid)
        }
        menuBar.integratesAllSimulatorsProvider = { [weak self] in
            self?.simulators.preference.allSimulators ?? true
        }
        menuBar.onSetIntegratesAllSimulators = { [weak self] all in
            Task { @MainActor [weak self] in await self?.simulators.setIntegratesAllSimulators(all) }
        }
    }

    /// Menu-bar entry point for the per-simulator switch.
    func setIntegration(enabled: Bool, for udid: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.simulators.setIntegration(enabled: enabled, for: udid)
            if let error = self.simulators.simulators.first(where: { $0.id == udid })?.error {
                self.showAlert(title: "Runtime integration", info: error)
            }
        }
    }

    /// Explicit, user-requested relaunch of an app that was already running
    /// before integration was enabled (or that is excluded from it). This is
    /// the only path that terminates an app, and it asks first because it
    /// ends the app's current state and any attached debug session.
    func relaunchRunningApp() {
        guard !relaunchInFlight else { return }
        relaunchInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.relaunchInFlight = false }
            guard let self else { return }
            await self.simulators.refresh()
            let candidates = self.simulators.simulators.flatMap { simulator in
                simulator.runningApps.filter { !$0.isInstrumented }.map { (simulator, $0) }
            }
            guard let (simulator, app) = candidates.first else {
                self.showAlert(
                    title: "Nothing to relaunch",
                    info: "Every running app in the booted simulators already has the Voly agent, or no app is running. Show the inspector to see each app's status."
                )
                return
            }
            let alert = NSAlert()
            alert.messageText = "Relaunch \(app.bundleIdentifier) with Voly?"
            alert.informativeText = """
                The app on \(simulator.device.name) will be terminated and launched again with the Voly agent. \
                Its current state is lost and an attached Xcode debug session will end.

                To avoid this, enable Runtime Integration for the simulator: apps launched afterwards \
                (including from Xcode) are inspectable without a relaunch.
                """
            alert.addButton(withTitle: "Relaunch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try await self.simulators.relaunch(bundleIdentifier: app.bundleIdentifier, on: simulator.id)
            } catch {
                log.error("relaunch failed: \(String(describing: error), privacy: .public)")
                self.showAlert(title: "Relaunch failed", info: error.localizedDescription)
            }
        }
    }

    #if DEBUG
    /// Scripted smoke runs only: PNG of the inspector panel's content view.
    func writeInspectorSnapshot(to url: URL) {
        guard let view = window.panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

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
