import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable, Hashable {
    case hierarchy, layout, props, userDefaults, urlTester

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hierarchy: return "Tree"
        case .layout: return "Layout"
        case .props: return "Props"
        case .userDefaults: return "UD"
        case .urlTester: return "URL"
        }
    }

    var symbol: String {
        switch self {
        case .hierarchy: return "list.bullet.indent"
        case .layout: return "square.3.layers.3d.down.left"
        case .props: return "slider.horizontal.3"
        case .userDefaults: return "tray.full"
        case .urlTester: return "link"
        }
    }

    /// Tabs that require a selection in the hierarchy.
    var requiresSelection: Bool {
        switch self {
        case .layout, .props: return true
        case .hierarchy, .userDefaults, .urlTester: return false
        }
    }
}
