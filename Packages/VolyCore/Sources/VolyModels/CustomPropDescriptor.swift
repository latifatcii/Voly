import Foundation

public struct CustomPropDescriptor: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let declaredType: DeclaredType
    public let isReadOnly: Bool
    public let source: Source
    public let currentValue: PropValue

    public enum Source: String, Codable, Sendable {
        case runtimeObjC
        case ibInspectable
        case kvc
        case registered
    }

    public enum DeclaredType: String, Codable, Sendable {
        case bool, int, double, string, color, cgRect, cgSize, cgPoint, url, enumCase, unknown
    }

    public init(
        name: String,
        declaredType: DeclaredType,
        isReadOnly: Bool,
        source: Source,
        currentValue: PropValue
    ) {
        self.name = name
        self.declaredType = declaredType
        self.isReadOnly = isReadOnly
        self.source = source
        self.currentValue = currentValue
    }
}

public struct PropertyBag: Codable, Sendable, Hashable {
    public let objectID: ObjectID
    public let view: [String: PropValue]
    public let layer: [String: PropValue]
    public let custom: [CustomPropDescriptor]

    public init(objectID: ObjectID, view: [String: PropValue], layer: [String: PropValue], custom: [CustomPropDescriptor]) {
        self.objectID = objectID
        self.view = view
        self.layer = layer
        self.custom = custom
    }
}
