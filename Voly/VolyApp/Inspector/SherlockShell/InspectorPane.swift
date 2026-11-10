import Foundation
import Observation

/// UI-only state for the inspector: the currently selected tab. Kept
/// separate from InspectorStateStore (which is protocol-level).
@MainActor
@Observable
final class InspectorPane {
    var currentTab: DetailTab

    init(tab: DetailTab = .hierarchy) {
        currentTab = tab
    }
}
