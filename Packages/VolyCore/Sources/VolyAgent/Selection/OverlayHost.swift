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
    private var measurementLayer: CAShapeLayer?
    private var measurementLabelLayers: [CATextLayer] = []

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
        clearMeasurement()
        highlightLayer?.removeFromSuperlayer()
        highlightLayer = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
    }

    public func showMeasurement(_ overlay: MeasurementOverlay) {
        ensureWindow(scene: UIApplication.shared.connectedScenes.first as? UIWindowScene)
        guard let window = overlayWindow,
              let root = window.rootViewController?.view
        else { return }

        // Remove any prior text labels.
        measurementLabelLayers.forEach { $0.removeFromSuperlayer() }
        measurementLabelLayers.removeAll()

        let layer = measurementLayer ?? {
            let l = CAShapeLayer()
            l.fillColor = UIColor.clear.cgColor
            l.strokeColor = UIColor.systemOrange.cgColor
            l.lineWidth = 1
            l.lineDashPattern = [4, 4]
            root.layer.addSublayer(l)
            measurementLayer = l
            return l
        }()

        let path = UIBezierPath()
        // "other" rect outline — in window coords, which is the overlay's coord space.
        path.append(UIBezierPath(rect: overlay.other.cg))
        // Guide segments.
        for guide in overlay.guides {
            switch guide {
            case .horizontal(let y, let x1, let x2, _):
                path.move(to: CGPoint(x: x1, y: y))
                path.addLine(to: CGPoint(x: x2, y: y))
            case .vertical(let x, let y1, let y2, _):
                path.move(to: CGPoint(x: x, y: y1))
                path.addLine(to: CGPoint(x: x, y: y2))
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = path.cgPath
        // If otherIsTransformed, draw with a heavier dash to communicate the
        // frame may be inaccurate under rotation.
        layer.lineDashPattern = overlay.otherIsTransformed ? [2, 3] : [4, 4]
        CATransaction.commit()

        // Render labels as separate CATextLayers so we can position them per-guide.
        for guide in overlay.guides {
            let (center, text) = labelInfo(for: guide)
            let tl = CATextLayer()
            tl.string = text + " pt"
            tl.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            tl.fontSize = 10
            tl.foregroundColor = UIColor.white.cgColor
            tl.backgroundColor = UIColor.systemOrange.cgColor
            tl.cornerRadius = 3
            tl.alignmentMode = .center
            tl.contentsScale = UIScreen.main.scale
            let size = CGSize(width: 36, height: 14)
            tl.frame = CGRect(x: center.x - size.width / 2,
                              y: center.y - size.height / 2,
                              width: size.width,
                              height: size.height)
            root.layer.addSublayer(tl)
            measurementLabelLayers.append(tl)
        }
    }

    public func clearMeasurement() {
        measurementLabelLayers.forEach { $0.removeFromSuperlayer() }
        measurementLabelLayers.removeAll()
        measurementLayer?.removeFromSuperlayer()
        measurementLayer = nil
    }

    private func labelInfo(for guide: MeasurementGuide) -> (CGPoint, String) {
        switch guide {
        case .horizontal(let y, let x1, let x2, let label):
            return (CGPoint(x: (x1 + x2) / 2, y: y - 8), label)
        case .vertical(let x, let y1, let y2, let label):
            return (CGPoint(x: x + 18, y: (y1 + y2) / 2), label)
        }
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
