import Foundation
import CoreGraphics

public struct CGPointCodable: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ p: CGPoint) { self.x = Double(p.x); self.y = Double(p.y) }
    public var cg: CGPoint { CGPoint(x: x, y: y) }
}

public struct CGSizeCodable: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public init(_ s: CGSize) { self.width = Double(s.width); self.height = Double(s.height) }
    public var cg: CGSize { CGSize(width: width, height: height) }
}

public struct CGRectCodable: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ r: CGRect) {
        self.x = Double(r.origin.x); self.y = Double(r.origin.y)
        self.width = Double(r.size.width); self.height = Double(r.size.height)
    }
    public var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct CGColorCodable: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init?(_ cg: CGColor?) {
        guard let cg else { return nil }
        let converted: CGColor
        if cg.colorSpace?.model == .rgb {
            converted = cg
        } else if let rgbSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let c = cg.converted(to: rgbSpace, intent: .defaultIntent, options: nil) {
            converted = c
        } else {
            return nil
        }
        guard let components = converted.components, components.count >= 3 else { return nil }
        self.red = Double(components[0])
        self.green = Double(components[1])
        self.blue = Double(components[2])
        self.alpha = components.count >= 4 ? Double(components[3]) : 1.0
    }

    public var cg: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var hex: String {
        let r = Int((max(0, min(1, red))) * 255)
        let g = Int((max(0, min(1, green))) * 255)
        let b = Int((max(0, min(1, blue))) * 255)
        let a = Int((max(0, min(1, alpha))) * 255)
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

public struct UIEdgeInsetsCodable: Codable, Sendable, Hashable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double
    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public static let zero = UIEdgeInsetsCodable(top: 0, left: 0, bottom: 0, right: 0)
}
