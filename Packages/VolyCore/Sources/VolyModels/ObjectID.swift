import Foundation

public typealias ObjectID = UInt64

public enum InspectorError: Error, Codable, Sendable, Equatable {
    case objectGone(ObjectID)
    case unsupportedProperty(String)
    case unsupportedValue
    case invalidCommand(String)
    case `internal`(String)
    /// The connection has not presented the agent's session token.
    case unauthorized
    /// The feature exists but can't run in this process (see message).
    case unavailable(String)

    public var humanDescription: String {
        switch self {
        case .objectGone(let id): return "Object \(id) has been deallocated."
        case .unsupportedProperty(let p): return "Property '\(p)' is not supported on this object."
        case .unsupportedValue: return "Value could not be converted for this property."
        case .invalidCommand(let c): return "Invalid command: \(c)"
        case .internal(let m): return "Internal error: \(m)"
        case .unauthorized: return "The agent rejected this connection (missing or wrong session token)."
        case .unavailable(let m): return m
        }
    }
}
