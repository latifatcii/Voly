import CoreGraphics
import Foundation

/// Width/height bounds the inspector window should respect when attached.
public struct SizeSpec: Sendable, Equatable {
    public let minWidth: CGFloat
    public let preferredWidth: CGFloat
    public let maxWidth: CGFloat
    public let minHeight: CGFloat

    public init(
        minWidth: CGFloat,
        preferredWidth: CGFloat,
        maxWidth: CGFloat,
        minHeight: CGFloat
    ) {
        self.minWidth = minWidth
        self.preferredWidth = preferredWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
    }

    public static let voly = SizeSpec(
        minWidth: 360,
        preferredWidth: 440,
        maxWidth: 560,
        minHeight: 500
    )
}
