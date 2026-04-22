#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "AXSimulatorLocator")

/// Production `SimulatorLocator` backed by the macOS Accessibility API.
/// Requires the user to grant Accessibility permission for Voly in
/// System Settings → Privacy & Security → Accessibility.
public final class AXSimulatorLocator: SimulatorLocator, @unchecked Sendable {
    private static let simulatorBundleID = "com.apple.iphonesimulator"

    public init() {}

    public func frontmostSimulatorFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.simulatorBundleID
        ).first else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first(where: { isWindowUsable($0) }) ?? windows.first
        else {
            return nil
        }

        guard let position = axPoint(window, attribute: kAXPositionAttribute),
              let size = axSize(window, attribute: kAXSizeAttribute)
        else {
            return nil
        }

        // AX returns top-left in screen coordinates (inverted Y). Convert to
        // Cocoa bottom-left by subtracting from the primary screen's height.
        let primary = NSScreen.screens.first?.frame ?? .zero
        let cocoaY = primary.height - position.y - size.height

        return CGRect(x: position.x, y: cocoaY, width: size.width, height: size.height)
    }

    private func isWindowUsable(_ window: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let minimized = minimizedRef as? Bool, minimized {
            return false
        }
        return true
    }

    private func axPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private func axSize(_ element: AXUIElement, attribute: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }
}

/// Helper: is the process trusted for Accessibility access?
public enum AccessibilityTrust {
    /// Returns true if trusted. `prompt=true` triggers macOS's "grant access"
    /// dialog the first time.
    public static func isTrusted(prompt: Bool) -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a `var` in the C header and trips
        // Swift 6 strict concurrency. The documented value is stable, so we
        // inline the string literal.
        let key = "AXTrustedCheckOptionPrompt"
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
#endif
