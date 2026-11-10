import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sizing captures for a model: a 3x iPhone screen is larger than a vision
/// model makes use of, and costs accordingly.
public enum MCPImage {
    public struct Fitted: Equatable, Sendable {
        public let png: Data
        public let width: Int
        public let height: Int
        public let originalWidth: Int
        public let originalHeight: Int
    }

    /// The PNG unchanged when its longest side is within `maxDimension`,
    /// otherwise scaled down to it. Nil when `png` can't be decoded.
    public static func fit(png: Data, maxDimension: Int) -> Fitted? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        guard max(width, height) > maxDimension else {
            return Fitted(png: png, width: width, height: height, originalWidth: width, originalHeight: height)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Fitted(
            png: output as Data, width: scaled.width, height: scaled.height,
            originalWidth: width, originalHeight: height
        )
    }
}
