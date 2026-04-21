import Foundation

public typealias ObjectID = UInt64

public enum InspectorError: Error, Codable, Sendable, Equatable {
    case objectGone(ObjectID)
    case unsupportedProperty(String)
    case unsupportedValue
    case invalidCommand(String)
    case `internal`(String)

    public var humanDescription: String {
        switch self {
        case .objectGone(let id): return "Object \(id) has been deallocated."
        case .unsupportedProperty(let p): return "Property '\(p)' is not supported on this object."
        case .unsupportedValue: return "Value could not be converted for this property."
        case .invalidCommand(let c): return "Invalid command: \(c)"
        case .internal(let m): return "Internal error: \(m)"
        }
    }
}
