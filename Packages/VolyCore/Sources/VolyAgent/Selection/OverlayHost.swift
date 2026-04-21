#if canImport(UIKit)
import UIKit
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

@MainActor
public final class OverlayHost {
    private unowned let registry: ObjectRegistry
    private var overlayWindow: UIWindow?
    private var highlightLayer: CAShapeLayer?

    public init(registry: ObjectRegistry) {
        self.registry = registry
    }

    public func highlight(viewID: ObjectID) {
        guard let view = registry.object(for: viewID) as? UIView else {
            clear()
            return
        }
        ensureWindow(scene: view.window?.windowScene)
        guard let overlay = overlayWindow,
              let overlayRoot = overlay.rootViewController?.view
        else { return }

        let frame = view.convert(view.bounds, to: overlayRoot)

        let layer = highlightLayer ?? {
            let l = CAShapeLayer()
            l.fillColor = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
            l.strokeColor = UIColor.systemBlue.cgColor
            l.lineWidth = 1
            overlayRoot.layer.addSublayer(l)
            highlightLayer = l
            return l
        }()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = UIBezierPath(rect: frame).cgPath
        CATransaction.commit()
    }

    public func clear() {
        highlightLayer?.removeFromSuperlayer()
        highlightLayer = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
    }

    private func ensureWindow(scene: UIWindowScene?) {
        if overlayWindow != nil { return }
        guard let scene = scene ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene) else { return }
        let w = UIWindow(windowScene: scene)
        w.accessibilityIdentifier = SnapshotBuilder.overlayIdentifier
        w.windowLevel = UIWindow.Level.alert
        w.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        w.rootViewController = root
        w.isUserInteractionEnabled = false
        w.isHidden = false
        overlayWindow = w
    }
}
#endif
