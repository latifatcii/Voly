#if canImport(UIKit)
import UIKit
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

/// In-process captures: the app's own windows, or one view. Full-display
/// captures are taken by the host through `simctl` instead.
///
/// UIKit drawing happens on the main actor; PNG encoding, the slow part, is
/// moved off it so a large capture doesn't stall the app's run loop.
@MainActor
enum ScreenshotRenderer {
    /// Guard against absurd allocations for runaway view sizes.
    private static let maxPixelDimension: CGFloat = 16_384

    static func capture(_ target: ScreenshotTarget, registry: ObjectRegistry) async throws -> ScreenshotImage {
        let rendered: Rendered
        switch target {
        case .application:
            rendered = try renderApplication()
        case .view(let id):
            guard let view = registry.object(for: id) as? UIView else {
                throw InspectorError.objectGone(id)
            }
            rendered = try render(view: view)
        }
        let image = rendered.image
        guard let cgImage = image.cgImage else {
            throw InspectorError.internal("Renderer produced no bitmap.")
        }
        let box = UncheckedImage(image: image)
        let png = await Task.detached(priority: .userInitiated) { box.image.pngData() }.value
        guard let png else { throw InspectorError.internal("PNG encoding failed.") }
        return ScreenshotImage(
            png: png,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            scale: Double(image.scale),
            orientation: rendered.orientation
        )
    }

    static func screenInfo() -> ScreenInfo {
        let scene = activeScene()
        return ScreenInfo(
            orientation: scene.map(orientation(of:)) ?? .unknown,
            scale: Double(scene?.screen.scale ?? 1)
        )
    }

    // MARK: - Rendering

    private struct Rendered {
        let image: UIImage
        let orientation: InterfaceOrientation
    }

    /// `UIImage` is immutable once rendered; this only carries it across to
    /// the encoding task.
    private struct UncheckedImage: @unchecked Sendable {
        let image: UIImage
    }

    /// Composite every app window bottom-to-top, skipping Voly's own overlay
    /// windows so the highlight and pick tint never appear in a capture.
    private static func renderApplication() throws -> Rendered {
        guard let scene = activeScene() else {
            throw InspectorError.unavailable("The app has no active window scene to capture.")
        }
        let bounds = scene.coordinateSpace.bounds
        let windows = scene.windows
            .filter { !$0.isVolyOverlay && !$0.isHidden && $0.alpha > 0.01 }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        guard !windows.isEmpty else {
            throw InspectorError.unavailable("The app has no visible windows to capture.")
        }
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format(scale: scene.screen.scale, size: bounds.size))
        let image = renderer.image { _ in
            for window in windows {
                window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
            }
        }
        return Rendered(image: image, orientation: orientation(of: scene))
    }

    private static func render(view: UIView) throws -> Rendered {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else {
            throw InspectorError.unavailable("The selected view has no size to capture.")
        }
        let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        guard bounds.width * scale <= maxPixelDimension, bounds.height * scale <= maxPixelDimension else {
            throw InspectorError.unavailable("The selected view is too large to capture in one image.")
        }
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format(scale: scale, size: bounds.size))
        let image = renderer.image { context in
            // drawHierarchy matches what's on screen (effects, materials) but
            // needs the view in a window; layer rendering is the fallback.
            if view.window == nil || !view.drawHierarchy(in: bounds, afterScreenUpdates: false) {
                view.layer.render(in: context.cgContext)
            }
        }
        let orientation = view.window?.windowScene.map(Self.orientation(of:)) ?? .unknown
        return Rendered(image: image, orientation: orientation)
    }

    private static func format(scale: CGFloat, size: CGSize) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        format.opaque = false
        return format
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func orientation(of scene: UIWindowScene) -> InterfaceOrientation {
        switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .unknown
        }
    }
}
#endif
