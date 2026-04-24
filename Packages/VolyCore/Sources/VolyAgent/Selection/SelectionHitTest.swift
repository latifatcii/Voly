#if canImport(UIKit)
import UIKit
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

/// Shared depth-first "deepest visible view under a point" walk. Used by
/// PickEngine (taps) and the client-side Mac hover monitor via `.measureHover`.
/// Deliberately ignores
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
    /// topmost visible view. We scope to `scene.keyWindow` when available —
    /// that's UIKit's "the window the user is interacting with," and it's
    /// the right target for an inspector pick.
    ///
    /// Falling back to every window caused stale / dismissed / empty
    /// UIWindows (which stay in `scene.windows` without being `isHidden`) to
    /// intercept clicks meant for the visible app window.
    public static func hitTest(in scene: UIWindowScene, at point: CGPoint,
                                registry: ObjectRegistry) -> ObjectID {
        let candidates: [UIWindow]
        if let key = scene.keyWindow,
           !key.isVolyOverlay, !key.isHidden, key.alpha > 0.01 {
            candidates = [key]
        } else {
            candidates = scene.windows
                .filter { !$0.isVolyOverlay && !$0.isHidden && $0.alpha > 0.01 }
                .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }
        }
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
