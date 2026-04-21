import CoreGraphics
import Foundation

/// Pure geometry. Given a Simulator window frame (or nil), a size spec for
/// the inspector, and the visible screen rect, decide where Voly should sit.
///
/// Conventions: all frames are Cocoa screen coordinates (origin bottom-left).
public enum AttachmentCalculator {
    public static func attach(
        simulatorFrame: CGRect?,
        voly: SizeSpec,
        screen: CGRect,
        gap: CGFloat = 6
    ) -> AttachmentResult {
        guard let sim = simulatorFrame else {
            return detachedFallback(voly: voly, screen: screen)
        }

        let roomRight = screen.maxX - sim.maxX - gap
        let roomLeft = sim.minX - screen.minX - gap

        let volyWidth: CGFloat
        let height = max(sim.height, voly.minHeight)
        let y = sim.minY

        if roomRight >= voly.minWidth {
            volyWidth = min(voly.preferredWidth, max(voly.minWidth, roomRight), voly.maxWidth)
            let frame = CGRect(x: sim.maxX + gap, y: y, width: volyWidth, height: height)
            return AttachmentResult(frame: clamp(frame, to: screen), edge: .right)
        }

        if roomLeft >= voly.minWidth {
            volyWidth = min(voly.preferredWidth, max(voly.minWidth, roomLeft), voly.maxWidth)
            let frame = CGRect(x: sim.minX - gap - volyWidth, y: y, width: volyWidth, height: height)
            return AttachmentResult(frame: clamp(frame, to: screen), edge: .left)
        }

        return detachedFallback(voly: voly, screen: screen)
    }

    private static func detachedFallback(voly: SizeSpec, screen: CGRect) -> AttachmentResult {
        let width = voly.preferredWidth
        let height = max(voly.minHeight, screen.height * 0.7)
        let x = screen.midX + (screen.width / 2 - width) / 2
        let y = screen.midY - height / 2
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return AttachmentResult(frame: clamp(frame, to: screen), edge: .detached)
    }

    private static func clamp(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(f.size.width, screen.width)
        f.size.height = min(f.size.height, screen.height)
        f.origin.x = max(screen.minX, min(f.origin.x, screen.maxX - f.size.width))
        f.origin.y = max(screen.minY, min(f.origin.y, screen.maxY - f.size.height))
        return f
    }
}
