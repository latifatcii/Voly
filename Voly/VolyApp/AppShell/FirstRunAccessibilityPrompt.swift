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
        alert.messageText = "Let Voly measure under the cursor"
        alert.informativeText = """
            Voly uses macOS Accessibility to track the cursor over the Simulator \
            for live measurements while picking. Without this permission everything \
            else still works, including docking next to the Simulator and selecting \
            views by clicking.
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
