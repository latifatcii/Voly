import Foundation

extension HierarchySnapshot {
    /// Returns the id of the window ViewNode whose subtree contains `id`,
    /// or nil if `id` is not found in this snapshot.
    public func containingWindowID(of id: ObjectID) -> ObjectID? {
        for scene in scenes {
            for window in scene.windowsInline {
                if subtreeContains(node: window, target: id) { return window.id }
            }
        }
        return nil
    }

    private func subtreeContains(node: ViewNode, target: ObjectID) -> Bool {
        if node.id == target { return true }
        for child in node.childrenInline ?? [] {
            if subtreeContains(node: child, target: target) { return true }
        }
        return false
    }
}
