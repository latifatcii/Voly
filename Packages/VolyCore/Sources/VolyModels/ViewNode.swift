import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

public struct ViewNode: Codable, Sendable, Identifiable, Hashable {
    public let id: ObjectID
    public let className: String
    public let moduleName: String?
    public let accessibilityIdentifier: String?
    public let owningViewControllerID: ObjectID?
    public let frame: CGRectCodable
    public let bounds: CGRectCodable
    public let center: CGPointCodable
    public let isHidden: Bool
    public let alpha: Double
    public let layer: LayerProps
    public let tintColor: CGColorCodable?
    public let clipsToBounds: Bool
    public let contentMode: Int
    public let constraintIDs: [ObjectID]
    public let childIDs: [ObjectID]
    public let childrenInline: [ViewNode]?

    public init(
        id: ObjectID,
        className: String,
        moduleName: String?,
        accessibilityIdentifier: String?,
        owningViewControllerID: ObjectID?,
        frame: CGRectCodable,
        bounds: CGRectCodable,
        center: CGPointCodable,
        isHidden: Bool,
        alpha: Double,
        layer: LayerProps,
        tintColor: CGColorCodable?,
        clipsToBounds: Bool,
        contentMode: Int,
        constraintIDs: [ObjectID],
        childIDs: [ObjectID],
        childrenInline: [ViewNode]?
    ) {
        self.id = id
        self.className = className
        self.moduleName = moduleName
        self.accessibilityIdentifier = accessibilityIdentifier
        self.owningViewControllerID = owningViewControllerID
        self.frame = frame
        self.bounds = bounds
        self.center = center
        self.isHidden = isHidden
        self.alpha = alpha
        self.layer = layer
        self.tintColor = tintColor
        self.clipsToBounds = clipsToBounds
        self.contentMode = contentMode
        self.constraintIDs = constraintIDs
        self.childIDs = childIDs
        self.childrenInline = childrenInline
    }
}

public struct SceneNode: Codable, Sendable, Identifiable, Hashable {
    public let id: ObjectID
    public let role: String
    public let title: String?
    public let windowIDs: [ObjectID]
    public let windowsInline: [ViewNode]

    public init(id: ObjectID, role: String, title: String?, windowIDs: [ObjectID], windowsInline: [ViewNode]) {
        self.id = id; self.role = role; self.title = title
        self.windowIDs = windowIDs; self.windowsInline = windowsInline
    }
}

public struct HierarchySnapshot: Codable, Sendable, Hashable {
    public let scenes: [SceneNode]
    public let issuedAt: Date
    public init(scenes: [SceneNode], issuedAt: Date) {
        self.scenes = scenes; self.issuedAt = issuedAt
    }
}
