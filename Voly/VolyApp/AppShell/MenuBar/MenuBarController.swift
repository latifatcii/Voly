import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let showHideItem = NSMenuItem(title: "Show Inspector", action: nil, keyEquivalent: "")
    private let attachItem = NSMenuItem(title: "Attach Running App", action: nil, keyEquivalent: "")
    private let autoAttachItem = NSMenuItem(title: "Auto-Attach", action: nil, keyEquivalent: "")

    var onToggle: () -> Void
    var onQuit: () -> Void
    var onAbout: () -> Void
    var onToggleAutoAttach: () -> Void
    var onAttachRunningApp: () -> Void

    var isInspectorVisible: Bool = false {
        didSet { showHideItem.title = isInspectorVisible ? "Hide Inspector" : "Show Inspector" }
    }

    var isAutoAttachEnabled: Bool = false {
        didSet { autoAttachItem.state = isAutoAttachEnabled ? .on : .off }
    }

    init(
        onToggle: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onAbout: @escaping () -> Void,
        onToggleAutoAttach: @escaping () -> Void,
        onAttachRunningApp: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onToggle = onToggle
        self.onQuit = onQuit
        self.onAbout = onAbout
        self.onToggleAutoAttach = onToggleAutoAttach
        self.onAttachRunningApp = onAttachRunningApp
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "viewfinder.rectangular",
                accessibilityDescription: "Voly"
            )
            button.image?.isTemplate = true
        }
        // Assigning the menu to the status item makes any click (left or right)
        // open the dropdown. Show/hide moves to the "Show Inspector" menu item
        // and the ⌃⌥⌘V global hotkey — standard macOS menu-bar app UX.
        statusItem.menu = menu

        showHideItem.target = self
        showHideItem.action = #selector(showHideSelected)
        menu.addItem(showHideItem)

        attachItem.target = self
        attachItem.action = #selector(attachRunningAppSelected)
        attachItem.keyEquivalent = "r"
        attachItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(attachItem)

        menu.addItem(.separator())

        autoAttachItem.target = self
        autoAttachItem.action = #selector(autoAttachSelected)
        menu.addItem(autoAttachItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Voly", action: #selector(aboutSelected), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Voly", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func showHideSelected() { onToggle() }
    @objc private func aboutSelected() { onAbout() }
    @objc private func quitSelected() { onQuit() }
    @objc private func autoAttachSelected() { onToggleAutoAttach() }
    @objc private func attachRunningAppSelected() { onAttachRunningApp() }
}
