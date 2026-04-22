import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable, Hashable {
    case hierarchy, layout, props, src, userDefaults, urlTester, preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hierarchy: return "Tree"
        case .layout: return "Layout"
        case .props: return "Props"
        case .src: return "Src"
        case .userDefaults: return "UD"
        case .urlTester: return "URL"
        case .preview: return "Pv"
        }
    }

    var symbol: String {
        switch self {
        case .hierarchy: return "list.bullet.indent"
        case .layout: return "square.3.layers.3d.down.left"
        case .props: return "slider.horizontal.3"
        case .src: return "doc.text"
        case .userDefaults: return "tray.full"
        case .urlTester: return "link"
        case .preview: return "rectangle.center.inset.filled"
        }
    }

    /// Tabs that require a selection in the hierarchy.
    var requiresSelection: Bool {
        switch self {
        case .layout, .props, .src: return true
        case .hierarchy, .userDefaults, .urlTester, .preview: return false
        }
    }
}
