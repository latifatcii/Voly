import Foundation
import VolyCodables

public struct LayerProps: Codable, Sendable, Hashable {
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: CGColorCodable?
    public var shadowColor: CGColorCodable?
    public var shadowOpacity: Double
    public var shadowRadius: Double
    public var shadowOffset: CGSizeCodable
    public var masksToBounds: Bool
    public var shouldRasterize: Bool
    public var rasterizationScale: Double
    public var opacity: Double
    public var isOpaque: Bool
    public var backgroundColor: CGColorCodable?
    public var contentsScale: Double

    public init(
        cornerRadius: Double,
        borderWidth: Double,
        borderColor: CGColorCodable?,
        shadowColor: CGColorCodable?,
        shadowOpacity: Double,
        shadowRadius: Double,
        shadowOffset: CGSizeCodable,
        masksToBounds: Bool,
        shouldRasterize: Bool,
        rasterizationScale: Double,
        opacity: Double,
        isOpaque: Bool,
        backgroundColor: CGColorCodable?,
        contentsScale: Double
    ) {
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.shadowColor = shadowColor
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.shadowOffset = shadowOffset
        self.masksToBounds = masksToBounds
        self.shouldRasterize = shouldRasterize
        self.rasterizationScale = rasterizationScale
        self.opacity = opacity
        self.isOpaque = isOpaque
        self.backgroundColor = backgroundColor
        self.contentsScale = contentsScale
    }
}
