import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

public enum ProtocolVersion {
    public static let current: Int = 1
    public static let bonjourServiceType = "_voly-agent._tcp"
    public static let defaultPort: UInt16 = 0
}

public struct MessageEnvelope: Codable, Sendable {
    public let id: UInt64
    public let kind: Kind
    public let payload: Data

    public enum Kind: String, Codable, Sendable {
        case command, response, event, error, binary
    }

    public init(id: UInt64, kind: Kind, payload: Data) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }
}

public struct HandshakeRequest: Codable, Sendable {
    public let clientName: String
    public let clientVersion: String
    public let protocolVersion: Int
    public init(clientName: String, clientVersion: String, protocolVersion: Int = ProtocolVersion.current) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion
    }
}

public struct HandshakeAccepted: Codable, Sendable {
    public let protocolVersion: Int
    public let sessionID: UUID
    public let agentName: String
    public let agentVersion: String
    public let bundleIdentifier: String?
    public let processName: String
    public init(protocolVersion: Int, sessionID: UUID, agentName: String, agentVersion: String, bundleIdentifier: String?, processName: String) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
    }
}

public struct PropertyChange: Codable, Sendable {
    public let property: String
    public let value: PropValue
    public init(property: String, value: PropValue) {
        self.property = property
        self.value = value
    }
}

public struct SetPropertyRequest: Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case view, layer, custom }
    public let objectID: ObjectID
    public let scope: Scope
    public let change: PropertyChange
    public init(objectID: ObjectID, scope: Scope, change: PropertyChange) {
        self.objectID = objectID
        self.scope = scope
        self.change = change
    }
}

public struct ConstraintChange: Codable, Sendable {
    public var constant: Double?
    public var priority: Float?
    public var isActive: Bool?
    public init(constant: Double? = nil, priority: Float? = nil, isActive: Bool? = nil) {
        self.constant = constant
        self.priority = priority
        self.isActive = isActive
    }
}

public struct SetConstraintRequest: Codable, Sendable {
    public let constraintID: ObjectID
    public let anchorObjectID: ObjectID
    public let change: ConstraintChange
    public init(constraintID: ObjectID, anchorObjectID: ObjectID, change: ConstraintChange) {
        self.constraintID = constraintID
        self.anchorObjectID = anchorObjectID
        self.change = change
    }
}

public struct UserDefaultsSetRequest: Codable, Sendable {
    public let suite: String?
    public let key: String
    public let value: PropValue
    public init(suite: String?, key: String, value: PropValue) {
        self.suite = suite
        self.key = key
        self.value = value
    }
}

public enum Command: Codable, Sendable {
    case handshake(HandshakeRequest)
    case getHierarchy
    case getSubtree(objectID: ObjectID, maxDepth: Int)
    case getProperties(objectID: ObjectID)
    case setProperty(SetPropertyRequest)
    case getConstraints(objectID: ObjectID)
    case setConstraint(SetConstraintRequest)
    case enterPickMode
    case exitPickMode
    case selectAt(x: Double, y: Double, sceneID: ObjectID)
    case userDefaultsList(suite: String?)
    case userDefaultsSet(UserDefaultsSetRequest)
    case userDefaultsDelete(suite: String?, key: String)
    case openURL(url: URL)
    case setPreviewConfig(PreviewConfig)
    case clearPreview
    case resolveSource(objectID: ObjectID)
    case ping
    case clearSelection
    case highlight(objectID: ObjectID)
    case measure(overlay: MeasurementOverlay)
    case clearMeasure
    case enterMeasureMode
    case exitMeasureMode
    case hoverAt(x: Double, y: Double, sceneID: ObjectID)
    /// Hit-test at cursor + compute measurement against anchor + draw overlay,
    /// all live on the agent. Replaces the `.hoverAt` + client-side
    /// `FrameMeasurement.compute` + `.measure(overlay:)` sequence, which fed
    /// stale snapshot windowFrames into the overlay.
    case measureHover(anchorID: ObjectID, x: Double, y: Double, sceneID: ObjectID)
}

public enum Response: Codable, Sendable {
    case handshakeAccepted(HandshakeAccepted)
    case hierarchy(HierarchySnapshot)
    case subtree(ViewNode)
    case properties(PropertyBag)
    case constraints([ConstraintNode])
    case pickModeChanged(Bool)
    case measureModeChanged(Bool)
    case selection(ObjectID)
    case hoverResult(ObjectID?)
    case measureHoverResult(otherID: ObjectID?, summary: MeasurementSummary?)
    case userDefaults([UserDefaultsItem])
    case urlResult(success: Bool, error: String?)
    case previewApplied(PreviewConfig.Applied)
    case sourceInfo(SourceInfo)
    case ack
    case pong
    case error(InspectorError)
}

public enum Event: Codable, Sendable {
    case hierarchyChanged(rootID: ObjectID, changedSubtrees: [ObjectID])
    case viewInvalidated(ObjectID)
    case selectionChanged(ObjectID)
    case connectionWarning(String)
    case hoverTarget(ObjectID?)
    case measureClick(ObjectID)
}
