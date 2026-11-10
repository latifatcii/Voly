import AppKit
import Foundation
import VolyHost

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let showHideItem = NSMenuItem(title: "Show Inspector", action: nil, keyEquivalent: "")
    private let relaunchItem = NSMenuItem(title: "Relaunch Running App with Voly…", action: nil, keyEquivalent: "")
    private let integrationItem = NSMenuItem(title: "Runtime Integration", action: nil, keyEquivalent: "")
    private let integrationMenu = NSMenu()
    private let agentsItem = NSMenuItem(title: "AI Agents", action: nil, keyEquivalent: "")
    private let agentsMenu = NSMenu()

    var onToggle: () -> Void
    var onQuit: () -> Void
    var onAbout: () -> Void
    var onRelaunchRunningApp: () -> Void
    /// Booted simulators, read each time the submenu opens.
    var simulatorsProvider: () -> [VolySimulatorManager.Simulator] = { [] }
    var onSetIntegration: (_ udid: String, _ enabled: Bool) -> Void = { _, _ in }
    /// Whether every booted simulator is integrated automatically.
    var integratesAllSimulatorsProvider: () -> Bool = { true }
    var onSetIntegratesAllSimulators: (Bool) -> Void = { _ in }
    /// What AI agents may do through Voly (MCP), read each time the submenu opens.
    var agentAccess: MCPService?

    var isInspectorVisible: Bool = false {
        didSet { showHideItem.title = isInspectorVisible ? "Hide Inspector" : "Show Inspector" }
    }

    init(
        onToggle: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onAbout: @escaping () -> Void,
        onRelaunchRunningApp: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onToggle = onToggle
        self.onQuit = onQuit
        self.onAbout = onAbout
        self.onRelaunchRunningApp = onRelaunchRunningApp
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
        // Shown as a hint; the working shortcut is the Simulator-scoped
        // hotkey (and ⌃⌥⌘V everywhere).
        showHideItem.keyEquivalent = "e"
        showHideItem.keyEquivalentModifierMask = [.command]
        menu.addItem(showHideItem)

        menu.addItem(.separator())

        // One entry per booted simulator; rebuilt whenever it opens.
        integrationMenu.delegate = self
        integrationItem.submenu = integrationMenu
        menu.addItem(integrationItem)

        relaunchItem.target = self
        relaunchItem.action = #selector(relaunchRunningAppSelected)
        relaunchItem.keyEquivalent = "r"
        relaunchItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(relaunchItem)

        agentsMenu.delegate = self
        agentsItem.submenu = agentsMenu
        menu.addItem(agentsItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Voly", action: #selector(aboutSelected), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Voly", action: #selector(quitSelected), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === agentsMenu {
            rebuildAgentsMenu()
            return
        }
        guard menu === integrationMenu else { return }
        menu.removeAllItems()
        let allItem = NSMenuItem(
            title: "All Booted Simulators",
            action: #selector(allSimulatorsSelected(_:)),
            keyEquivalent: ""
        )
        allItem.target = self
        allItem.state = integratesAllSimulatorsProvider() ? .on : .off
        allItem.toolTip = "Load the Voly agent into apps launched in any booted simulator. Uncheck a simulator below to leave it alone."
        menu.addItem(allItem)
        menu.addItem(.separator())

        let simulators = simulatorsProvider()
        guard !simulators.isEmpty else {
            let empty = NSMenuItem(title: "No booted simulators", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for simulator in simulators {
            let item = NSMenuItem(
                title: "\(simulator.device.name) — \(simulator.runtimeName)",
                action: #selector(integrationSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = simulator.id
            item.state = simulator.integration.isActive ? .on : .off
            item.isEnabled = !simulator.isBusy
            if case .unsupported(let reason, _) = simulator.integration {
                item.toolTip = "Not supported on this runtime: \(reason)"
            } else {
                item.toolTip = "Load the Voly agent into apps launched in this simulator, without relaunching them. Applies to apps started after it is turned on."
            }
            menu.addItem(item)
        }
    }

    // MARK: - AI agents

    private func rebuildAgentsMenu() {
        agentsMenu.removeAllItems()
        guard let access = agentAccess else { return }

        let inspect = NSMenuItem(
            title: "Allow Agents to Inspect Apps", action: #selector(agentInspectSelected(_:)), keyEquivalent: ""
        )
        inspect.target = self
        inspect.state = access.isEnabled ? .on : .off
        inspect.toolTip = "Let AI coding agents (Claude Code, Cursor, Codex, …) read the view tree, properties, constraints and screenshots of apps Voly is connected to. Local only."
        agentsMenu.addItem(inspect)

        let change = NSMenuItem(
            title: "Allow Agents to Change the App", action: #selector(agentChangesSelected(_:)), keyEquivalent: ""
        )
        change.target = access.isEnabled ? self : nil
        change.state = access.isEnabled && access.allowsChanges ? .on : .off
        change.isEnabled = access.isEnabled
        change.toolTip = "Also let agents change the running app: view properties, constraints, navigation, language, user defaults, relaunching. Nothing is written to your source."
        agentsMenu.addItem(change)

        agentsMenu.addItem(.separator())
        for (title, text) in [
            ("Copy Setup Command for Claude Code", MCPRelay.claudeCodeSetupCommand),
            ("Copy Setup Command for Codex", MCPRelay.codexSetupCommand),
            ("Copy Configuration for Other Agents", MCPRelay.genericConfiguration),
        ] {
            let item = NSMenuItem(title: title, action: #selector(copyAgentSetupSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            item.toolTip = text
            agentsMenu.addItem(item)
        }

        agentsMenu.addItem(.separator())
        let status = NSMenuItem(title: Self.describe(access), action: nil, keyEquivalent: "")
        status.isEnabled = false
        agentsMenu.addItem(status)
    }

    private static func describe(_ access: MCPService) -> String {
        if let error = access.listenError { return "Not available: \(error)" }
        guard let last = access.lastToolCall else { return "No agent has asked for anything yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = Date().timeIntervalSince(last.date) < 5
            ? "just now"
            : formatter.localizedString(for: last.date, relativeTo: Date())
        let count = access.toolCallCount
        return "Last request: \(last.name), \(when) (\(count) so far)"
    }

    @objc private func agentInspectSelected(_ sender: NSMenuItem) {
        agentAccess?.isEnabled = sender.state != .on
    }

    @objc private func agentChangesSelected(_ sender: NSMenuItem) {
        agentAccess?.allowsChanges = sender.state != .on
    }

    @objc private func copyAgentSetupSelected(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func integrationSelected(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        onSetIntegration(udid, sender.state != .on)
    }

    @objc private func allSimulatorsSelected(_ sender: NSMenuItem) {
        onSetIntegratesAllSimulators(sender.state != .on)
    }

    @objc private func showHideSelected() { onToggle() }
    @objc private func aboutSelected() { onAbout() }
    @objc private func quitSelected() { onQuit() }
    @objc private func relaunchRunningAppSelected() { onRelaunchRunningApp() }
}
