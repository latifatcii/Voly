import AppKit
import SwiftUI
import Combine
import VolyHost

@MainActor
final class InspectorWindowController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    var onClose: () -> Void = {}
    /// ⌘E pressed while the inspector panel has keyboard focus.
    var onToggleShortcut: () -> Void = {} {
        didSet { (panel as? InspectorPanel)?.onToggleShortcut = onToggleShortcut }
    }
    /// When setFrame-ing programmatically, set this true so didMove doesn't
    /// mis-flag as a user drag.
    private var isProgrammaticMove = false
    private(set) var userHasDetached = false

    init(session: InspectorSession, initialTab: DetailTab = .hierarchy) {
        let content = NSHostingView(rootView: InspectorShell(session: session, initialTab: initialTab))
        // The panel's frame is driven by docking, never by its content.
        content.sizingOptions = []
        panel = InspectorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voly"
        // The SwiftUI header draws the title and fills the title bar area;
        // AppKit keeps only the close button. Always dark: see VolyTheme.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(VolyTheme.panel)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = content
        // See `place(_:)`: it floats only while a device window is in front.
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
    ///
    /// - Parameter floating: false when the app in front is not a device
    ///   window's: the panel comes up in front as asked, but as an ordinary
    ///   window, so that app's windows cover it again once the user is back
    ///   in them.
    func show(at frame: CGRect, floating: Bool = true) {
        setFrame(frame, animated: false)
        panel.level = floating ? .floating : .normal
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        userHasDetached = false
    }

    /// Put the panel where it belongs among other apps' windows: floating
    /// while the Simulator or an emulator is in front, and otherwise an
    /// ordinary window that stays with the device window behind whatever
    /// the user turned to.
    func place(_ placement: InspectorLayering.Placement) {
        guard panel.isVisible else { return }
        panel.level = placement.floats ? .floating : .normal
        switch placement.order {
        case .front?: panel.orderFrontRegardless()
        case .above(let number)?: panel.order(.above, relativeTo: number)
        case .below(let number)?: panel.order(.below, relativeTo: number)
        case nil: break
        }
    }

    /// The panel's number in the window server's list.
    var windowNumber: Int { panel.windowNumber }

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

/// The inspector's panel. Handles ⌘E itself so the show/hide shortcut also
/// works when the panel has keyboard focus.
private final class InspectorPanel: NSPanel {
    var onToggleShortcut: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "e" {
            onToggleShortcut()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
