import Foundation
import VolyModels
import VolyCodables

enum ConnectionStatus: String, Sendable {
    case disconnected, connecting, connected
}

@MainActor
@Observable
final class InspectorStateStore {
    var connectionStatus: ConnectionStatus = .disconnected
    var hierarchy: HierarchySnapshot?
    var selectedViewID: ObjectID?
    var pickModeActive = false
    /// IDs whose DisclosureGroup in the hierarchy browser is open. Owned here
    /// (rather than on each NodeRow's @State) so `expandAncestors(of:)` can
    /// open the chain when a new selection arrives via pick or programmatic select.
    var expandedNodeIDs: Set<ObjectID> = []
    var propertyBag: PropertyBag?
    var constraints: [ConstraintNode] = []
    var userDefaults: [UserDefaultsItem] = []
    var urlHistory: [URL] = []
    var previewApplied: PreviewConfig.Applied?
    var previewConfig = PreviewConfig(size: .init(width: 390, height: 844))

    /// Merge a refreshed subtree into our cached hierarchy so the UI reflects new values.
    func merge(subtree: ViewNode) {
        guard var snapshot = hierarchy else { return }
        snapshot = HierarchySnapshot(
            scenes: snapshot.scenes.map { scene in
                let newWindows = scene.windowsInline.map { window in
                    merge(target: window, with: subtree)
                }
                return SceneNode(
                    id: scene.id,
                    role: scene.role,
                    title: scene.title,
                    windowIDs: scene.windowIDs,
                    windowsInline: newWindows
                )
            },
            issuedAt: snapshot.issuedAt
        )
        hierarchy = snapshot
    }

    private func merge(target: ViewNode, with subtree: ViewNode) -> ViewNode {
        if target.id == subtree.id {
            return subtree
        }
        guard let children = target.childrenInline else { return target }
        let newChildren = children.map { merge(target: $0, with: subtree) }
        return ViewNode(
            id: target.id,
            className: target.className,
            moduleName: target.moduleName,
            accessibilityIdentifier: target.accessibilityIdentifier,
            owningViewControllerID: target.owningViewControllerID,
            frame: target.frame,
            bounds: target.bounds,
            center: target.center,
            isHidden: target.isHidden,
            alpha: target.alpha,
            layer: target.layer,
            tintColor: target.tintColor,
            clipsToBounds: target.clipsToBounds,
            contentMode: target.contentMode,
            constraintIDs: target.constraintIDs,
            childIDs: target.childIDs,
            childrenInline: newChildren
        )
    }

    /// Find a node by id inside the current hierarchy snapshot (linear search).
    func findNode(id: ObjectID) -> ViewNode? {
        guard let snapshot = hierarchy else { return nil }
        for scene in snapshot.scenes {
            for window in scene.windowsInline {
                if let found = findNode(id: id, in: window) { return found }
            }
        }
        return nil
    }

    private func findNode(id: ObjectID, in node: ViewNode) -> ViewNode? {
        if node.id == id { return node }
        for child in node.childrenInline ?? [] {
            if let found = findNode(id: id, in: child) { return found }
        }
        return nil
    }

    /// Which window's subtree contains `id`, per the cached snapshot.
    /// Used to decide whether two views can be measured against each other
    /// (cross-window measurements are meaningless in window coords).
    func containingWindowID(of id: ObjectID) -> ObjectID? {
        hierarchy?.containingWindowID(of: id)
    }

    /// Walk the cached hierarchy and insert every ancestor of `id` into
    /// `expandedNodeIDs`. No-op if `id` is not in the cached tree.
    func expandAncestors(of id: ObjectID) {
        guard let snapshot = hierarchy else { return }
        for scene in snapshot.scenes {
            for window in scene.windowsInline {
                if collectAncestors(of: id, in: window, into: &expandedNodeIDs) {
                    return
                }
            }
        }
    }

    /// Returns true if `target` was found in this subtree; inserts every
    /// strict ancestor into `acc` along the way.
    private func collectAncestors(
        of target: ObjectID,
        in node: ViewNode,
        into acc: inout Set<ObjectID>
    ) -> Bool {
        if node.id == target { return true }
        for child in node.childrenInline ?? [] {
            if collectAncestors(of: target, in: child, into: &acc) {
                acc.insert(node.id)
                return true
            }
        }
        return false
    }
}
