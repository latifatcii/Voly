import AppKit
import Foundation
import VolyHost

@MainActor
enum FirstRunAccessibilityPrompt {
    private static let shownKey = "voly.accessibility.firstPromptShown"

    /// Shows a one-time NSAlert if Accessibility isn't granted AND we haven't
    /// already nudged the user once.
    static func runIfNeeded() {
        if AccessibilityTrust.isTrusted(prompt: false) { return }
        if UserDefaults.standard.bool(forKey: shownKey) { return }
        UserDefaults.standard.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = "Let Voly follow the Simulator"
        alert.informativeText = """
            Voly uses macOS Accessibility to read the Simulator's window position \
            so it can dock next to it automatically. Without this permission Voly \
            still works, but it opens at a fixed position.
            """
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Triggers the system prompt AND opens Settings.
            _ = AccessibilityTrust.isTrusted(prompt: true)
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
