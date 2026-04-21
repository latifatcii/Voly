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
    private var hotkey: GlobalHotkey?
    private var attachmentObservation: Task<Void, Never>?
    private var toggleInFlight = false

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
            onToggle: {}, onQuit: {}, onAbout: {}, onToggleAutoAttach: {}
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
        attachment.stop()
        window.hide()
        menuBar.isInspectorVisible = false
        stopObservingAttachment()
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
                case .disabled, .foreign:
                    try await self.autoAttach.ensureInstalled()
                    StaleProcessNudge.runIfNeeded()
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
            }
        } catch {
            log.error("autoAttach install on start failed: \(String(describing: error), privacy: .public)")
            menuBar.isAutoAttachEnabled = false
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
            self?.menuBar.isInspectorVisible = false
            self?.attachment.stop()
            self?.stopObservingAttachment()
        }
        menuBar.onToggle = { [weak self] in self?.toggleInspector() }
        menuBar.onQuit = { [weak self] in self?.quit() }
        menuBar.onAbout = { NSApp.orderFrontStandardAboutPanel(nil) }
        menuBar.onToggleAutoAttach = { [weak self] in self?.toggleAutoAttach() }
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
