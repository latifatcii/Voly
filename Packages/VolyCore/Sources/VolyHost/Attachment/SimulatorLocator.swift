import CoreGraphics
import Foundation

/// Locates the Simulator app's frontmost window. Implementations may be
/// AX-based, process-based, or fake (for tests).
public protocol SimulatorLocator: Sendable {
    /// Returns the frontmost Simulator window frame in Cocoa screen
    /// coordinates (origin = bottom-left of primary screen), or nil if the
    /// Simulator isn't running, has no window, or Accessibility permission
    /// was denied.
    func frontmostSimulatorFrame() -> CGRect?
}

/// Test-friendly stub whose return value can be set directly.
public final class StubSimulatorLocator: SimulatorLocator, @unchecked Sendable {
    public var frame: CGRect?
    public private(set) var callCount: Int = 0

    public init(frame: CGRect? = nil) { self.frame = frame }

    public func frontmostSimulatorFrame() -> CGRect? {
        callCount += 1
        return frame
    }
}
