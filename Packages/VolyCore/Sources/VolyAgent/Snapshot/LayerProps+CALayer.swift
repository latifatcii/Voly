#if canImport(UIKit)
import UIKit
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

extension LayerProps {
    @MainActor
    public init(caLayer layer: CALayer) {
        self.init(
            cornerRadius: Double(layer.cornerRadius),
            borderWidth: Double(layer.borderWidth),
            borderColor: CGColorCodable(layer.borderColor),
            shadowColor: CGColorCodable(layer.shadowColor),
            shadowOpacity: Double(layer.shadowOpacity),
            shadowRadius: Double(layer.shadowRadius),
            shadowOffset: CGSizeCodable(layer.shadowOffset),
            masksToBounds: layer.masksToBounds,
            shouldRasterize: layer.shouldRasterize,
            rasterizationScale: Double(layer.rasterizationScale),
            opacity: Double(layer.opacity),
            isOpaque: layer.isOpaque,
            backgroundColor: CGColorCodable(layer.backgroundColor),
            contentsScale: Double(layer.contentsScale)
        )
    }
}
#endif
