import Foundation
import VolyCodables

public indirect enum PropValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case color(CGColorCodable)
    case rect(CGRectCodable)
    case size(CGSizeCodable)
    case point(CGPointCodable)
    case url(URL)
    case arrayOf([PropValue])
    case dictOf([String: PropValue])

    public func asDouble() throws -> Double {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .bool(let v): return v ? 1 : 0
        default: throw InspectorError.unsupportedValue
        }
    }

    public func asInt() throws -> Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .bool(let v): return v ? 1 : 0
        default: throw InspectorError.unsupportedValue
        }
    }

    public func asBool() throws -> Bool {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .double(let v): return v != 0
        default: throw InspectorError.unsupportedValue
        }
    }

    public func asString() throws -> String {
        if case .string(let s) = self { return s }
        throw InspectorError.unsupportedValue
    }

    public func asColor() throws -> CGColorCodable {
        if case .color(let c) = self { return c }
        throw InspectorError.unsupportedValue
    }

    public func asSize() throws -> CGSizeCodable {
        if case .size(let s) = self { return s }
        throw InspectorError.unsupportedValue
    }

    public func asRect() throws -> CGRectCodable {
        if case .rect(let r) = self { return r }
        throw InspectorError.unsupportedValue
    }

    public func asPoint() throws -> CGPointCodable {
        if case .point(let p) = self { return p }
        throw InspectorError.unsupportedValue
    }

    public func asURL() throws -> URL {
        if case .url(let u) = self { return u }
        throw InspectorError.unsupportedValue
    }
}
