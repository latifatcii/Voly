import Foundation
import VolyModels

/// How a constraint reads in the inspector: a short label naming what it
/// does and the value it does it with — "Leading to" / "UIImageView.trailing
/// + 33", "Width equals" / "173" — instead of the raw solver equation.
public struct ConstraintPresentation: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(_ constraint: ConstraintNode) {
        let first = Self.name(of: constraint.firstAttribute)
        let relation: String
        switch constraint.relation {
        case .equal: relation = "equals"
        case .greaterThanOrEqual: relation = "≥"
        case .lessThanOrEqual: relation = "≤"
        }

        guard constraint.secondAttribute != .notAnAttribute else {
            // A fixed dimension: "Width equals 173".
            label = "\(first.capitalizedFirst) \(relation)"
            value = Self.number(constraint.constant)
            return
        }

        label = constraint.relation == .equal
            ? "\(first.capitalizedFirst) to"
            : "\(first.capitalizedFirst) \(relation)"
        var parts = [Self.secondItem(in: constraint.summary)
            .map { "\($0).\(constraint.secondAttribute.rawValue)" } ?? constraint.secondAttribute.rawValue]
        if constraint.multiplier != 1 { parts.append("× \(Self.number(constraint.multiplier))") }
        if constraint.constant > 0 {
            parts.append("+ \(Self.number(constraint.constant))")
        } else if constraint.constant < 0 {
            parts.append("− \(Self.number(-constraint.constant))")
        }
        value = parts.joined(separator: " ")
    }

    /// `leading` → "leading", `centerX` → "center X", `lastBaseline` → "last baseline".
    static func name(of attribute: LayoutAttribute) -> String {
        var words: [String] = []
        var current = ""
        for character in attribute.rawValue {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
            .map { $0.count == 1 ? $0.uppercased() : $0.lowercased() }
            .joined(separator: " ")
    }

    /// The agent's summary is `First.attr = Second.attr × m + c @p`; the
    /// second item's class is the only place its name travels.
    static func secondItem(in summary: String) -> String? {
        let tokens = summary.split(separator: " ")
        guard tokens.count >= 3, let dot = tokens[2].lastIndex(of: ".") else { return nil }
        let name = String(tokens[2][..<dot])
        return name.isEmpty || name == "nil" ? nil : name
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
