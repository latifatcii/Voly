import AppKit
import SwiftUI
import Combine

@MainActor
final class InspectorWindowController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    var onClose: () -> Void = {}
    /// When setFrame-ing programmatically, set this true so didMove doesn't
    /// mis-flag as a user drag.
    private var isProgrammaticMove = false
    private(set) var userHasDetached = false

    init(session: InspectorSession) {
        let content = NSHostingView(rootView: InspectorRootView(session: session))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voly"
        panel.contentView = content
        panel.level = .floating
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive.
        // .moveToActiveSpace is the right pick for a toggle-to-show accessory:
        // the panel materializes on whatever Space the user is on when they
        // hit the hotkey, rather than existing in all Spaces at once.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.setFrameAutosaveName("") // disable frame autosave (attachment drives position)

        super.init()
        panel.delegate = self
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows + orders-front without stealing focus from the frontmost app.
    func show(at frame: CGRect) {
        setFrame(frame, animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        userHasDetached = false
    }

    func setFrame(_ frame: CGRect, animated: Bool) {
        isProgrammaticMove = true
        panel.setFrame(frame, display: true, animate: animated)
        DispatchQueue.main.async { [weak self] in self?.isProgrammaticMove = false }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        onClose()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        if !isProgrammaticMove { userHasDetached = true }
    }
}
