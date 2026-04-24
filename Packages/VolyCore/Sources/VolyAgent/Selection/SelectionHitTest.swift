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
    /// topmost visible view in a *user* window. UIKit-private UIWindow
    /// subclasses (UITextEffectsWindow, UIRemoteKeyboardWindow, etc.) are
    /// excluded — they host system UI (text-selection affordances,
    /// keyboard, autocorrect) and become `keyWindow` when there's text
    /// focus, which would otherwise intercept picks meant for the app's
    /// own window.
    public static func hitTest(in scene: UIWindowScene, at point: CGPoint,
                                registry: ObjectRegistry) -> ObjectID {
        let candidates = scene.windows
            .filter { !$0.isVolyOverlay && !$0.isHidden && $0.alpha > 0.01 }
            .filter { !isSystemWindow($0) }
            .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }
        for w in candidates {
            let local = w.convert(point, from: nil)
            if let found = deepest(in: w, at: local) {
                return registry.id(for: found)
            }
        }
        return 0
    }

    /// Blocklist of UIKit-internal UIWindow subclasses we don't want to
    /// accept clicks against. Class-name match (string) avoids a compile-time
    /// dependency on private headers.
    private static func isSystemWindow(_ window: UIWindow) -> Bool {
        let name = String(describing: type(of: window))
        if name == "UITextEffectsWindow" { return true }
        if name == "UIRemoteKeyboardWindow" { return true }
        if name == "UISystemInputAssistantWindow" { return true }
        if name == "UITextInteractionInteractiveRefinementWindow" { return true }
        if name.hasPrefix("_UI") { return true }
        return false
    }
}
#endif
