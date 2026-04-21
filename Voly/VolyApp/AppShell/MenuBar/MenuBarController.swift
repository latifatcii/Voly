import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let showHideItem = NSMenuItem(title: "Show Inspector", action: nil, keyEquivalent: "")

    var onToggle: () -> Void
    var onQuit: () -> Void
    var onAbout: () -> Void

    var isInspectorVisible: Bool = false {
        didSet { showHideItem.title = isInspectorVisible ? "Hide Inspector" : "Show Inspector" }
    }

    init(
        onToggle: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onAbout: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onToggle = onToggle
        self.onQuit = onQuit
        self.onAbout = onAbout
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "viewfinder.rectangular",
                accessibilityDescription: "Voly"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        showHideItem.target = self
        showHideItem.action = #selector(showHideSelected)
        menu.addItem(showHideItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Voly", action: #selector(aboutSelected), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Voly", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            onToggle()
        }
    }

    @objc private func showHideSelected() { onToggle() }
    @objc private func aboutSelected() { onAbout() }
    @objc private func quitSelected() { onQuit() }
}
