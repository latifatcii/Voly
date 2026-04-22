import Foundation

/// Turns camelCase property identifiers into space-separated, title-cased
/// display labels. Strips `is` prefixes from common Bool getters.
///
///     cornerRadius       → "Corner Radius"
///     isOpaque           → "Opaque"
///     masksToBounds      → "Masks To Bounds"
///     backgroundColor    → "Background Color"
enum PropertyNameFormatter {
    static func humanize(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("is"), s.count > 2,
           let third = s.dropFirst(2).first, third.isUppercase {
            s = String(s.dropFirst(2))
        }
        var words: [String] = []
        var current = ""
        for ch in s {
            if ch.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Friendly label for specific known (propertyName, value) pairs where the raw
/// number masks an enum. Extend as new cases surface.
enum PropertyValueFormatter {
    static func label(forProperty name: String, intValue: Int64) -> String? {
        switch name {
        case "contentMode":
            switch intValue {
            case 0: return "Scale to Fill"
            case 1: return "Aspect Fit"
            case 2: return "Aspect Fill"
            case 3: return "Redraw"
            case 4: return "Center"
            case 5: return "Top"
            case 6: return "Bottom"
            case 7: return "Left"
            case 8: return "Right"
            case 9: return "Top Left"
            case 10: return "Top Right"
            case 11: return "Bottom Left"
            case 12: return "Bottom Right"
            default: return nil
            }
        default:
            return nil
        }
    }
}
