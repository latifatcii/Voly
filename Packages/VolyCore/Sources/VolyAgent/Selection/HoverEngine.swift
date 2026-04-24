#if canImport(UIKit)
import UIKit
import OSLog

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.VolyAgent", category: "HoverEngine")

/// Measurement-mode overlay on the simulator side. Draws the orange tint
/// so the user knows measure mode is on, and captures click-to-anchor via
/// UITapGestureRecognizer (clicks work reliably across all sim targets).
///
/// Hover capture lives on the Mac side (SimulatorHoverMonitor) because
/// UIHoverGestureRecognizer doesn't fire on iPhone iOS Simulator.
@MainActor
public final class HoverEngine {
    public enum Notification {
        /// `object: NSNumber` — the clicked ObjectID.
        public static let didClick = Foundation.Notification.Name("voly.hover.didClick")
    }

    unowned let registry: ObjectRegistry
    private var hoverWindow: UIWindow?
    private var suspendedWindowInteraction: [UIWindow: Bool] = [:]
    private var currentSceneID: ObjectID = 0

    public init(registry: ObjectRegistry) {
        self.registry = registry
    }

    public func enter() {
        guard hoverWindow == nil else {
            log.notice("enter: already active, no-op")
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else {
            log.error("enter: no active UIWindowScene — aborting")
            return
        }
        currentSceneID = registry.id(for: scene)

        let w = UIWindow(windowScene: scene)
        w.accessibilityIdentifier = SnapshotBuilder.overlayIdentifier
        w.windowLevel = UIWindow.Level.alert + 2
        w.frame = scene.coordinateSpace.bounds
        w.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.10)

        let root = HoverRootVC(
            onClick: { [weak self] point in self?.handleClick(at: point, in: scene) }
        )
        w.rootViewController = root
        w.isUserInteractionEnabled = true
        w.makeKeyAndVisible()
        hoverWindow = w

        suspendedWindowInteraction.removeAll(keepingCapacity: true)
        for other in scene.windows where !other.isVolyOverlay && other !== w {
            suspendedWindowInteraction[other] = other.isUserInteractionEnabled
            other.isUserInteractionEnabled = false
        }
        log.notice("enter: overlay window up at level \(w.windowLevel.rawValue, privacy: .public), scene=\(self.currentSceneID)")
    }

    public func exit() {
        hoverWindow?.isHidden = true
        hoverWindow?.resignKey()
        hoverWindow = nil

        for (window, wasEnabled) in suspendedWindowInteraction {
            window.isUserInteractionEnabled = wasEnabled
        }
        suspendedWindowInteraction.removeAll(keepingCapacity: true)

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let realWindow = scene.windows.first(where: { !$0.isVolyOverlay }) {
            realWindow.makeKey()
        }
    }

    private func handleClick(at point: CGPoint, in scene: UIWindowScene) {
        let id = SelectionHitTest.hitTest(in: scene, at: point, registry: registry)
        guard id != 0 else { return }
        log.notice("handleClick at \(String(describing: point), privacy: .public) → id=\(id)")
        NotificationCenter.default.post(
            name: Notification.didClick,
            object: NSNumber(value: id)
        )
    }
}

private final class HoverRootVC: UIViewController {
    private let onClick: (CGPoint) -> Void
    init(onClick: @escaping (CGPoint) -> Void) {
        self.onClick = onClick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = HoverRootView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = true
        v.addGestureRecognizer(tap)

        view = v
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onClick(g.location(in: view))
    }
}

private final class HoverRootView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { true }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { self }
}
#endif
