import CoreGraphics
import Foundation

/// Output of `AttachmentCalculator.attach`. Describes where and how the
/// inspector window should sit relative to the Simulator.
public struct AttachmentResult: Sendable, Equatable {
    public enum Edge: String, Sendable, Equatable {
        case right, left, detached
    }
    public let frame: CGRect
    public let edge: Edge

    public init(frame: CGRect, edge: Edge) {
        self.frame = frame
        self.edge = edge
    }
}
