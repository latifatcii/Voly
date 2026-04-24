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

    private func deepest(in node: ViewNode, at point: CGPoint) -> ObjectID? {
        guard !node.isHidden, node.alpha > 0.01 else { return nil }
        let rect = (node.windowFrame ?? node.frame).cg
        guard rect.contains(point) else { return nil }
        for child in (node.childrenInline ?? []).reversed() {
            if let found = deepest(in: child, at: point) { return found }
        }
        return node.id
    }
}
