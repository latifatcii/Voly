#if canImport(UIKit)
import UIKit

/// Shared depth-first "deepest visible view under a point" walk. Used by both
/// PickEngine (taps) and HoverEngine (pointer moves). Deliberately ignores
/// `isUserInteractionEnabled` — UILabel defaults to false and must still be
/// inspectable.
@MainActor
public enum SelectionHitTest {
    /// Walk the subtree rooted at `view` depth-first (children first, reversed
    /// so the topmost sibling wins) and return the deepest non-hidden view
    /// whose bounds contain `point` (in its own coord space). Returns nil when
    /// `view` itself is hidden or out of bounds.
    public static func deepest(in view: UIView, at point: CGPoint) -> UIView? {
        guard !view.isHidden,
              view.alpha > 0.01,
              view.point(inside: point, with: nil)
        else { return nil }
        for child in view.subviews.reversed() where !child.isVolyOverlay {
            let cp = view.convert(point, to: child)
            if let deeper = deepest(in: child, at: cp) { return deeper }
        }
        return view
    }

    /// Given a scene and a point in that scene's coordinate space, find the
    /// topmost visible view across all non-overlay windows (honoring window
    /// level order). Returns 0 if nothing matches.
    public static func hitTest(in scene: UIWindowScene, at point: CGPoint,
                                registry: ObjectRegistry) -> ObjectID {
        let candidates = scene.windows
            .filter { !$0.isVolyOverlay }
            .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }
        for w in candidates {
            let local = w.convert(point, from: nil)
            if let found = deepest(in: w, at: local) {
                return registry.id(for: found)
            }
        }
        return 0
    }
}
#endif
