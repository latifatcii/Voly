import Foundation

public enum LayoutAttribute: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom, leading, trailing
    case width, height
    case centerX, centerY
    case lastBaseline, firstBaseline
    case leftMargin, rightMargin, topMargin, bottomMargin
    case leadingMargin, trailingMargin
    case centerXWithinMargins, centerYWithinMargins
    case notAnAttribute
}

public enum LayoutRelation: String, Codable, Sendable {
    case lessThanOrEqual, equal, greaterThanOrEqual
}

public struct ConstraintNode: Codable, Sendable, Identifiable, Hashable {
    public let id: ObjectID
    public let firstItemID: ObjectID?
    public let firstAttribute: LayoutAttribute
    public let relation: LayoutRelation
    public let secondItemID: ObjectID?
    public let secondAttribute: LayoutAttribute
    public var constant: Double
    public var multiplier: Double
    public var priority: Float
    public var identifier: String?
    public var isActive: Bool
    public let ownerID: ObjectID
    public let isSystemGenerated: Bool
    public let summary: String

    public init(
        id: ObjectID,
        firstItemID: ObjectID?,
        firstAttribute: LayoutAttribute,
        relation: LayoutRelation,
        secondItemID: ObjectID?,
        secondAttribute: LayoutAttribute,
        constant: Double,
        multiplier: Double,
        priority: Float,
        identifier: String?,
        isActive: Bool,
        ownerID: ObjectID,
        isSystemGenerated: Bool,
        summary: String
    ) {
        self.id = id
        self.firstItemID = firstItemID
        self.firstAttribute = firstAttribute
        self.relation = relation
        self.secondItemID = secondItemID
        self.secondAttribute = secondAttribute
        self.constant = constant
        self.multiplier = multiplier
        self.priority = priority
        self.identifier = identifier
        self.isActive = isActive
        self.ownerID = ownerID
        self.isSystemGenerated = isSystemGenerated
        self.summary = summary
    }
}
