import Foundation

/// The pixel size a PNG declares in its header, without decoding it.
public enum PNGSize {
    public static func read(_ png: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard png.count >= 24, png.prefix(8).elementsEqual(signature) else { return nil }
        // IHDR is always the first chunk: length(4) "IHDR"(4) width(4) height(4).
        let bytes = [UInt8](png.prefix(24))
        guard bytes[12...15].elementsEqual(Array("IHDR".utf8)) else { return nil }
        func number(_ range: ClosedRange<Int>) -> Int { bytes[range].reduce(0) { $0 << 8 | Int($1) } }
        let width = number(16...19), height = number(20...23)
        return width > 0 && height > 0 ? (width, height) : nil
    }
}
