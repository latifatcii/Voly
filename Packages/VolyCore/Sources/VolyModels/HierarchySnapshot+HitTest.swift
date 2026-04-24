import Foundation
import CoreGraphics

extension HierarchySnapshot {
    /// Depth-first pick against cached `windowFrame` data. Mirrors the
    /// agent-side SelectionHitTest.deepest, but uses snapshot frames
    /// instead of the live view tree. Returns nil when the point doesn't
    /// land on any non-hidden, non-zero-alpha view of the target scene.
    public func hitTest(at point: CGPoint, sceneID: ObjectID) -> ObjectID? {
        guard let scene = scenes.first(where: { $0.id == sceneID }) else {
            return nil
        }
        for window in scene.windowsInline.reversed() {
            if let hit = deepest(in: window, at: point) {
                return hit
            }
        }
        return nil
    }

    /// Same walk as `hitTest(at:sceneID:)` but returns the full path of
    /// ViewNodes the walk traversed, for diagnostics. Last element is the
    /// returned hit.
    public func hitTestPath(at point: CGPoint, sceneID: ObjectID) -> [ViewNode] {
        guard let scene = scenes.first(where: { $0.id == sceneID }) else {
            return []
        }
        for window in scene.windowsInline.reversed() {
            var path: [ViewNode] = []
            if deepestWithPath(in: window, at: point, path: &path) {
                return path
            }
        }
        return []
    }

    private func deepest(in node: ViewNode, at point: CGPoint) -> ObjectID? {
        guard !node.isHidden, node.alpha > 0.01 else { return nil }
        let rect = (node.windowFrame ?? node.frame).cg
        guard rect.contains(point) else { return nil }
        for child in (node.childrenInline ?? []).reversed() {
            if let found = deepest(in: child, at: point) { return found }
        }
        return node.id
    }

    private func deepestWithPath(
        in node: ViewNode,
        at point: CGPoint,
        path: inout [ViewNode]
    ) -> Bool {
        guard !node.isHidden, node.alpha > 0.01 else { return false }
        let rect = (node.windowFrame ?? node.frame).cg
        guard rect.contains(point) else { return false }
        path.append(node)
        for child in (node.childrenInline ?? []).reversed() {
            if deepestWithPath(in: child, at: point, path: &path) { return true }
        }
        return true
    }
}
