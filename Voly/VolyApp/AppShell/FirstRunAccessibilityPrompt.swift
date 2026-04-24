import AppKit
import Foundation
import VolyHost

@MainActor
enum FirstRunAccessibilityPrompt {
    /// Shows an NSAlert at launch whenever Accessibility isn't granted. No
    /// UserDefaults dedup — a previous "shown" flag would silence us across
    /// TCC resets and re-installs (common with ad-hoc-signed DMG builds),
    /// leaving the user with no obvious path back. The alert dedupes itself
    /// naturally: once granted, the trust check above returns true.
    static func runIfNeeded() {
        if AccessibilityTrust.isTrusted(prompt: false) { return }

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
