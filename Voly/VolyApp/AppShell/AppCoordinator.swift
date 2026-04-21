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
    private var hotkey: GlobalHotkey?
    private var attachmentObservation: Task<Void, Never>?

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
            onToggle: {}, onQuit: {}, onAbout: {}
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
        // Seed the window with an immediate calculation before first tick.
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

    private func wireCallbacks() {
        window.onClose = { [weak self] in
            self?.menuBar.isInspectorVisible = false
            self?.attachment.stop()
            self?.stopObservingAttachment()
        }
        menuBar.onToggle = { [weak self] in self?.toggleInspector() }
        menuBar.onQuit = { [weak self] in self?.quit() }
        menuBar.onAbout = { NSApp.orderFrontStandardAboutPanel(nil) }
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
