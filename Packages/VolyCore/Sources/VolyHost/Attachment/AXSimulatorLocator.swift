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

    /// Used to emit the AX tree dump once per process for diagnostics.
    nonisolated(unsafe) private static var didDumpTree = false

    public func iosScreenRegionInScreen() -> IosScreenBoundsOnScreen? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.simulatorBundleID
        ).first else {
            log.info("iosScreenRegionInScreen: Simulator not running")
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            log.info("iosScreenRegionInScreen: AXWindows attribute unavailable (Accessibility denied?)")
            return nil
        }
        guard let window = windows.first(where: { isWindowUsable($0) }) ?? windows.first else {
            log.info("iosScreenRegionInScreen: no usable simulator window (found \(windows.count) window(s))")
            return nil
        }

        guard let windowRect = windowFrameTopLeft(window) else {
            log.info("iosScreenRegionInScreen: no position/size on the window")
            return nil
        }

        // One-shot dump of the AX tree so we can iterate on the heuristic
        // without guessing.
        if !Self.didDumpTree {
            Self.didDumpTree = true
            log.notice("=== AX tree dump (sim window \(String(describing: windowRect), privacy: .public)) ===")
            dumpTree(window, depth: 0)
            log.notice("=== end AX tree dump ===")
        }

        guard let screenRect = findIosScreenRect(inside: window, windowRect: windowRect) else {
            log.info("iosScreenRegionInScreen: no candidate rect matched the heuristic inside window")
            return nil
        }

        // AX returns top-left origin; flip to Cocoa bottom-left.
        let primary = NSScreen.screens.first?.frame ?? .zero
        let cocoaY = primary.height - screenRect.origin.y - screenRect.height
        let cocoaRect = CGRect(
            x: screenRect.origin.x,
            y: cocoaY,
            width: screenRect.width,
            height: screenRect.height
        )
        return IosScreenBoundsOnScreen(frame: cocoaRect)
    }

    private func dumpTree(_ element: AXUIElement, depth: Int) {
        guard depth < 12 else { return }
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "?"

        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? ""

        var idRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idRef)
        let axid = idRef as? String ?? ""

        let pos = axPoint(element, attribute: kAXPositionAttribute)
        let size = axSize(element, attribute: kAXSizeAttribute)
        let indent = String(repeating: "  ", count: depth)
        let sizeStr = size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "--×--"
        let posStr = pos.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "(?,?)"
        let idStr = axid.isEmpty ? "" : " id=\(axid)"
        let subStr = subrole.isEmpty ? "" : " sub=\(subrole)"
        log.notice("\(indent, privacy: .public)\(role, privacy: .public)\(subStr, privacy: .public)\(idStr, privacy: .public) \(posStr, privacy: .public) \(sizeStr, privacy: .public)")

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                dumpTree(child, depth: depth + 1)
            }
        }
    }

    /// Returns the window's top-left-origin frame in screen coords.
    private func windowFrameTopLeft(_ window: AXUIElement) -> CGRect? {
        guard let pos = axPoint(window, attribute: kAXPositionAttribute),
              let size = axSize(window, attribute: kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Depth-first search for the largest AXImage inside the window. The
    /// Simulator renders iOS as an image element nested several layers deep
    /// inside the window's view hierarchy.
    private func findIosScreenRect(inside window: AXUIElement, windowRect: CGRect) -> CGRect? {
        var best: CGRect?
        walkAX(window, windowRect: windowRect, best: &best, depth: 0)
        return best
    }

    private func walkAX(_ element: AXUIElement, windowRect: CGRect, best: inout CGRect?, depth: Int) {
        guard depth < 20 else { return }

        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Skip the window itself (we want children, not the whole window).
        // Skip obvious chrome: toolbars, buttons, etc.
        let isChrome = (role == "AXWindow" && depth == 0)
            || role == "AXToolbar"
            || role == "AXButton"
            || role == "AXMenuBar"
            || role == "AXStaticText"

        if !isChrome {
            if let pos = axPoint(element, attribute: kAXPositionAttribute),
               let size = axSize(element, attribute: kAXSizeAttribute),
               size.width > 100, size.height > 100 {
                let rect = CGRect(origin: pos, size: size)
                // Must be strictly inside the window (not the window itself)
                // and smaller than it.
                let isInside = windowRect.contains(rect)
                    && rect.size != windowRect.size
                if isInside {
                    if best == nil || rect.width * rect.height > best!.width * best!.height {
                        best = rect
                    }
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                walkAX(child, windowRect: windowRect, best: &best, depth: depth + 1)
            }
        }
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
