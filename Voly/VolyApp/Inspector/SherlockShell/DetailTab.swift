import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable, Hashable {
    case simulators, hierarchy, layout, props, userDefaults, urlTester

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .simulators: return "iphone"
        case .hierarchy: return "list.bullet.indent"
        case .layout: return "ruler"
        case .props: return "slider.horizontal.3"
        case .userDefaults: return "tray.full"
        case .urlTester: return "link"
        }
    }

    /// Full name, shown as the tab's tooltip (the tab itself is an icon).
    var title: String {
        switch self {
        case .simulators: return "Simulators"
        case .hierarchy: return "View Tree"
        case .layout: return "Layout"
        case .props: return "Properties"
        case .userDefaults: return "User Defaults"
        case .urlTester: return "URL Tester"
        }
    }

    /// Tabs whose content concerns the selected view (as opposed to the
    /// simulators or the app as a whole).
    var isAboutSelection: Bool {
        switch self {
        case .hierarchy, .layout, .props: return true
        case .simulators, .userDefaults, .urlTester: return false
        }
    }

    /// Tabs that require a selection in the hierarchy.
    var requiresSelection: Bool {
        switch self {
        case .layout, .props: return true
        case .simulators, .hierarchy, .userDefaults, .urlTester: return false
        }
    }
}
