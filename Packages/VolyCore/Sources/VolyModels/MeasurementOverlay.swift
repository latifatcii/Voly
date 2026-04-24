import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

public struct MeasurementOverlay: Codable, Sendable, Hashable {
    public let anchor: CGRectCodable
    public let other: CGRectCodable
    public let otherIsTransformed: Bool
    public let guides: [MeasurementGuide]
    public let summary: MeasurementSummary

    public init(
        anchor: CGRectCodable,
        other: CGRectCodable,
        otherIsTransformed: Bool,
        guides: [MeasurementGuide],
        summary: MeasurementSummary
    ) {
        self.anchor = anchor
        self.other = other
        self.otherIsTransformed = otherIsTransformed
        self.guides = guides
        self.summary = summary
    }
}

public enum MeasurementGuide: Codable, Sendable, Hashable {
    case horizontal(y: Double, x1: Double, x2: Double, label: String)
    case vertical(x: Double, y1: Double, y2: Double, label: String)
}

public struct MeasurementSummary: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sideBySide, containment, overlap, sameView, crossWindow
    }
    public let kind: Kind
    public let horizontal: Double?
    public let vertical: Double?

    public init(kind: Kind, horizontal: Double?, vertical: Double?) {
        self.kind = kind
        self.horizontal = horizontal
        self.vertical = vertical
    }
}
