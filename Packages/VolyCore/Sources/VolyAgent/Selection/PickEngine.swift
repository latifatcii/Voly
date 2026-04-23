#if canImport(UIKit)
import UIKit
import OSLog
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif
#if !VOLY_UNIFIED_BUILD
import VolyProtocol
#endif

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.VolyAgent", category: "PickEngine")

@MainActor
public final class PickEngine {
    public enum Notification {
        public static let didPick = Foundation.Notification.Name("voly.pick.didPick")
        public static let didCancel = Foundation.Notification.Name("voly.pick.didCancel")
    }

    unowned let registry: ObjectRegistry
    private weak var overlay: OverlayHost?
    private var pickWindow: UIWindow?
    /// When pick mode is active, we set `isUserInteractionEnabled = false` on every
    /// non-overlay window in the scene. This dict remembers the previous value so
    /// we can restore it on exit.
    private var suspendedWindowInteraction: [UIWindow: Bool] = [:]

    public init(registry: ObjectRegistry, overlay: OverlayHost?) {
        self.registry = registry
        self.overlay = overlay
    }

    public func enter() {
        guard pickWindow == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }

        let w = UIWindow(windowScene: scene)
        w.accessibilityIdentifier = SnapshotBuilder.overlayIdentifier
        w.windowLevel = UIWindow.Level.alert + 1
        // Explicit frame = scene bounds so taps anywhere on screen hit us.
        w.frame = scene.coordinateSpace.bounds
        // Light tint so the user knows they're in pick mode.
        w.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        let root = PickRootVC { [weak self] point in
            self?.handleTap(at: point, in: scene)
        }
        w.rootViewController = root
        w.isUserInteractionEnabled = true
        w.makeKeyAndVisible()
        pickWindow = w

        // Freeze event delivery to every non-overlay window so buttons, gestures,
        // and navigation don't fire while the user is tapping to pick.
        suspendedWindowInteraction.removeAll(keepingCapacity: true)
        for other in scene.windows where !other.isVolyOverlay && other !== w {
            suspendedWindowInteraction[other] = other.isUserInteractionEnabled
            other.isUserInteractionEnabled = false
        }
    }

    public func exit() {
        pickWindow?.isHidden = true
        pickWindow?.resignKey()
        pickWindow = nil

        // Restore each window's previous interaction state.
        for (window, wasEnabled) in suspendedWindowInteraction {
            window.isUserInteractionEnabled = wasEnabled
        }
        suspendedWindowInteraction.removeAll(keepingCapacity: true)

        // Restore the app's real key window.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let realWindow = scene.windows.first(where: { !$0.isVolyOverlay }) {
            realWindow.makeKey()
        }
        // Note: we deliberately do NOT clear the selection highlight here.
        // exit() runs after every successful pick (observePickNotifications in
        // VolyAgentRuntime calls highlight() then pick.exit()), and clearing
        // would erase the highlight instantly. Clearing is driven by the
        // explicit Command.clearSelection path instead.
    }

    public func select(at point: CGPoint, sceneID: ObjectID) throws -> ObjectID {
        guard let scene = registry.object(for: sceneID) as? UIWindowScene else {
            throw InspectorError.objectGone(sceneID)
        }
        return hit(at: point, in: scene)
    }

    private func handleTap(at point: CGPoint, in scene: UIWindowScene) {
        let id = hit(at: point, in: scene)
        log.notice("handleTap at \(String(describing: point), privacy: .public) → picked id=\(id)")
        // Pass id as the `object` so Foundation's bridging can't silently mangle
        // the UInt64 through NSNumber shortening.
        NotificationCenter.default.post(name: Notification.didPick, object: NSNumber(value: id))
    }

    private func hit(at point: CGPoint, in scene: UIWindowScene) -> ObjectID {
        SelectionHitTest.hitTest(in: scene, at: point, registry: registry)
    }
}

private final class PickRootVC: UIViewController {
    private let onTap: (CGPoint) -> Void
    init(onTap: @escaping (CGPoint) -> Void) {
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let v = PickRootView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        // Use a single-tap recognizer that cancels touches in view so they never
        // leak to underlying app buttons/controls.
        let g = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        g.cancelsTouchesInView = true
        v.addGestureRecognizer(g)
        view = v
    }
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onTap(g.location(in: view))
    }
}

/// Greedy overlay: every touch inside my bounds belongs to me. Underlying app
/// windows never see the event.
private final class PickRootView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { true }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { self }
}
#endif
