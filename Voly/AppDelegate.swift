import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let session = InspectorSession()
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FirstRunAccessibilityPrompt.runIfNeeded()

        coordinator = AppCoordinator(session: session)
        coordinator?.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    // Never terminate when the inspector window closes — the menu-bar icon
    // keeps the process alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
