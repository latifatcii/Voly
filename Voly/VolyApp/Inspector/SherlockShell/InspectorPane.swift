import Foundation
import Observation
import VolyModels

/// UI-only state for the Sherlock-style inspector: the currently selected tab,
/// sidebar visibility, and which selections have their inheritance chain
/// expanded. Kept separate from InspectorStateStore (which is protocol-level).
@MainActor
@Observable
final class InspectorPane {
    var currentTab: DetailTab = .layout
    var sidebarVisible: Bool = true
    /// Per-selection expansion. Cleared automatically when selection changes;
    /// callers invoke `resetInheritance(for:)` on selection change.
    private var inheritanceExpanded: Set<ObjectID> = []

    func isInheritanceExpanded(_ id: ObjectID) -> Bool {
        inheritanceExpanded.contains(id)
    }

    func toggleInheritance(_ id: ObjectID) {
        if inheritanceExpanded.contains(id) {
            inheritanceExpanded.remove(id)
        } else {
            inheritanceExpanded.insert(id)
        }
    }

    /// Clear expanded state when selection moves to a different view.
    func resetInheritance(for newSelection: ObjectID?) {
        inheritanceExpanded.removeAll(keepingCapacity: true)
    }
}
