#if canImport(AppKit)
import CoreGraphics
import Foundation

/// A window as the window server reports it. `bounds` use the global
/// top-left coordinate space (y grows downward from the primary display).
public struct OnScreenWindow: Equatable, Sendable {
    public let ownerPID: pid_t
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect

    public init(ownerPID: pid_t, layer: Int, alpha: Double, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }
}

/// Finds the simulator the user is working in: the Simulator app's device
/// window that is frontmost in the window server's z-order, i.e. the one
/// most recently focused.
///
/// The window list needs no Accessibility (or Screen Recording) permission
/// for geometry, so docking next to the Simulator works without either.
public enum SimulatorWindowPicker {
    /// Smaller than any device window, larger than the Simulator's other
    /// windows (per-device title strips, the Apple TV remote).
    static let minimumShortSide: CGFloat = 180
    static let minimumLongSide: CGFloat = 300

    /// - Parameter windows: on-screen windows, front to back.
    public static func frontmostDeviceWindow(in windows: [OnScreenWindow], simulatorPID: pid_t) -> OnScreenWindow? {
        windows.first { window in
            window.ownerPID == simulatorPID
                && window.layer == 0
                && window.alpha > 0
                && min(window.bounds.width, window.bounds.height) >= minimumShortSide
                && max(window.bounds.width, window.bounds.height) >= minimumLongSide
        }
    }

    /// On-screen windows of the current Space, front to back.
    public static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            return OnScreenWindow(
                ownerPID: pid,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                bounds: bounds
            )
        }
    }

    /// Window-server bounds (top-left origin) → Cocoa screen coordinates
    /// (bottom-left origin of the primary display).
    public static func cocoaFrame(for bounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: primaryScreenHeight - bounds.minY - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }
}
#endif
