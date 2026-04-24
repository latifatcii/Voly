import Foundation
import Observation
import VolyModels

/// UI-only state for the two-view measurement feature: which view the user
/// is currently hovering over in the hierarchy tree, and which (if any) is
/// pinned via ⌥-click.
///
/// Selection itself lives on `InspectorStateStore.selectedViewID` — that's
/// the anchor. This pane tracks the *other* view.
@MainActor
@Observable
final class MeasurementPane {
    var hoverID: ObjectID?
    var pinnedID: ObjectID?

    /// The "other" view for measurement purposes: pin wins over hover so a
    /// pinned pair keeps showing while the mouse moves.
    var effectiveOtherID: ObjectID? { pinnedID ?? hoverID }

    func reset() {
        hoverID = nil
        pinnedID = nil
    }

    /// Toggle the pin: if `id` is already pinned, unpin; otherwise pin `id`.
    func togglePin(_ id: ObjectID) {
        pinnedID = (pinnedID == id) ? nil : id
    }
}
