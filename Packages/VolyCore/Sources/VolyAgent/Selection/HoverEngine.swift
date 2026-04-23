#if canImport(UIKit)
import UIKit
import OSLog

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.VolyAgent", category: "HoverEngine")

/// Measurement-mode overlay. When active, intercepts pointer hover + clicks on
/// the simulator and emits Foundation notifications the runtime forwards to the
/// client as `.hoverTarget` / `.measureClick` events.
@MainActor
public final class HoverEngine {
    public enum Notification {
        /// `object: NSNumber` — the hovered ObjectID, or `NSNull` when the
        /// cursor is outside the simulator or hit-test returned 0.
        public static let didHover = Foundation.Notification.Name("voly.hover.didHover")
        /// `object: NSNumber` — the clicked ObjectID.
        public static let didClick = Foundation.Notification.Name("voly.hover.didClick")
    }

    unowned let registry: ObjectRegistry
    private var hoverWindow: UIWindow?
    private var suspendedWindowInteraction: [UIWindow: Bool] = [:]
    private var currentSceneID: ObjectID = 0

    // Throttle state: deadline-based trailing coalesce at ~33 ms.
    private var pendingHoverID: ObjectID?
    private var lastEmittedID: ObjectID?
    private var throttleTask: Task<Void, Never>?

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
        // Above PickEngine's alert+1 so they can never visually stack (in
        // practice only one is active — mutual exclusion is enforced client-
        // and dispatcher-side — but defensive positioning is cheap).
        w.windowLevel = UIWindow.Level.alert + 2
        w.frame = scene.coordinateSpace.bounds
        // Bumped from 0.04 to 0.10 so it's visibly obvious measure mode is on.
        w.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.10)

        let root = HoverRootVC(
            onHover: { [weak self] point in self?.handleHover(at: point, in: scene) },
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
        throttleTask?.cancel()
        throttleTask = nil
        pendingHoverID = nil
        lastEmittedID = nil

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

    private func handleHover(at point: CGPoint, in scene: UIWindowScene) {
        let id = SelectionHitTest.hitTest(in: scene, at: point, registry: registry)
        log.debug("handleHover: point=\(String(describing: point), privacy: .public) → id=\(id)")
        scheduleEmit(id: id == 0 ? nil : id)
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

    private func scheduleEmit(id: ObjectID?) {
        pendingHoverID = id
        if throttleTask != nil { return }
        throttleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.throttleTask = nil
            let toEmit = self.pendingHoverID
            if toEmit != self.lastEmittedID {
                self.lastEmittedID = toEmit
                log.notice("emit didHover: id=\(toEmit.map(String.init) ?? "nil", privacy: .public)")
                let payload: Any = toEmit.map(NSNumber.init(value:)) ?? NSNull()
                NotificationCenter.default.post(
                    name: Notification.didHover,
                    object: payload
                )
            }
        }
    }
}

private final class HoverRootVC: UIViewController, UIPointerInteractionDelegate {
    private let onHover: (CGPoint) -> Void
    private let onClick: (CGPoint) -> Void
    init(onHover: @escaping (CGPoint) -> Void,
         onClick: @escaping (CGPoint) -> Void) {
        self.onHover = onHover
        self.onClick = onClick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = HoverRootView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        // UIHoverGestureRecognizer — primary path on iPad / devices with
        // pointer support natively enabled.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        v.addGestureRecognizer(hover)

        // UIPointerInteraction — more reliable on iPhone iOS Simulator where
        // the simulator often forwards Mac mouse as pointer events but not as
        // hover-gesture events. `regionFor:` fires on every pointer move.
        let pointer = UIPointerInteraction(delegate: self)
        v.addInteraction(pointer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = true
        v.addGestureRecognizer(tap)

        view = v
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        onHover(g.location(in: view))
    }
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onClick(g.location(in: view))
    }

    // MARK: UIPointerInteractionDelegate

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        // request.location is in the interaction view's coord space, which is
        // our greedy HoverRootView == scene bounds.
        onHover(request.location)
        return defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Keep the system cursor — we're just tracking location.
        return nil
    }
}

/// Same greedy-capture pattern as PickRootView: every touch inside our bounds
/// belongs to us.
private final class HoverRootView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { true }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { self }
}
#endif
