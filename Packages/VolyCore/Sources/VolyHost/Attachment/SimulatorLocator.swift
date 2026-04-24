import CoreGraphics
import Foundation

/// Rectangle on screen where the iOS "device screen" is rendered inside
/// the Simulator window. Cocoa bottom-left screen coordinates.
public struct IosScreenBoundsOnScreen: Sendable, Hashable {
    public let frame: CGRect
    public init(frame: CGRect) { self.frame = frame }
}

/// Locates the Simulator app's frontmost window. Implementations may be
/// AX-based, process-based, or fake (for tests).
public protocol SimulatorLocator: Sendable {
    /// Returns the frontmost Simulator window frame in Cocoa screen
    /// coordinates (origin = bottom-left of primary screen), or nil if the
    /// Simulator isn't running, has no window, or Accessibility permission
    /// was denied.
    func frontmostSimulatorFrame() -> CGRect?

    /// Returns the iOS screen region inside the Simulator window (the area
    /// where iOS actually renders, excluding the sim's toolbar and bezel),
    /// in Cocoa bottom-left screen coords. Nil on any lookup failure.
    func iosScreenRegionInScreen() -> IosScreenBoundsOnScreen?
}

/// Test-friendly stub whose return values can be set directly.
public final class StubSimulatorLocator: SimulatorLocator, @unchecked Sendable {
    public var frame: CGRect?
    public var screenRegion: IosScreenBoundsOnScreen?
    public private(set) var frameCallCount: Int = 0
    public private(set) var regionCallCount: Int = 0

    public init(frame: CGRect? = nil, screenRegion: IosScreenBoundsOnScreen? = nil) {
        self.frame = frame
        self.screenRegion = screenRegion
    }

    public func frontmostSimulatorFrame() -> CGRect? {
        frameCallCount += 1
        return frame
    }

    public func iosScreenRegionInScreen() -> IosScreenBoundsOnScreen? {
        regionCallCount += 1
        return screenRegion
    }
}
