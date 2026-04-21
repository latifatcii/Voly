import AppKit
import Foundation

@MainActor
enum StaleProcessNudge {
    private static let shownKey = "voly.autoAttach.nudgeShown"
    private static let xcodeBundleID = "com.apple.dt.Xcode"
    private static let simulatorBundleID = "com.apple.iphonesimulator"

    /// Shows a one-time NSAlert if Xcode or Simulator.app is running AND the
    /// nudge hasn't been shown this install epoch. Call after
    /// `AutoAttachInstaller.ensureInstalled()` completes.
    static func runIfNeeded() {
        if UserDefaults.standard.bool(forKey: shownKey) { return }

        let xcodeRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: xcodeBundleID).isEmpty
        let simRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: simulatorBundleID).isEmpty

        guard xcodeRunning || simRunning else { return }

        UserDefaults.standard.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = "Auto-attach is enabled"
        let names = [xcodeRunning ? "Xcode" : nil, simRunning ? "Simulator" : nil]
            .compactMap { $0 }
            .joined(separator: " and ")
        alert.informativeText = """
            Voly now injects VolyAgent into every simulator app launched from \
            now on. \(names) is running and needs to be restarted once before \
            auto-attach takes effect in that session.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Clears the one-time flag. Call when the user toggles auto-attach off
    /// then back on so the next install epoch can re-nudge if still needed.
    static func resetEpoch() {
        UserDefaults.standard.removeObject(forKey: shownKey)
    }
}
