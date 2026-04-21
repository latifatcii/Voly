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
    }

    public func exit() {
        pickWindow?.isHidden = true
        pickWindow?.resignKey()
        pickWindow = nil
        // Restore the app's real key window.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let realWindow = scene.windows.first(where: { !$0.isVolyOverlay }) {
            realWindow.makeKey()
        }
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

    private func deepest(in view: UIView, at point: CGPoint) -> UIView? {
        guard view.isUserInteractionEnabled,
              !view.isHidden,
              view.alpha > 0.01,
              view.point(inside: point, with: nil)
        else { return nil }
        for child in view.subviews.reversed() where !child.isVolyOverlay {
            let cp = view.convert(point, to: child)
            if let deeper = deepest(in: child, at: cp) { return deeper }
        }
        return view
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
