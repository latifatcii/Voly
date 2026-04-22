import Foundation
import CoreGraphics
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

/// Pure geometry for the two-view measurement overlay. Given an `anchor` view
/// and an `other` view (both in the same window coord space), produces a
/// `MeasurementOverlay` describing the guide segments + pt labels the agent
/// should draw, plus a `MeasurementSummary` for the client's header badge.
public enum FrameMeasurement {
    public static func compute(
        anchor: ViewNode,
        other: ViewNode,
        sharedWindow: Bool
    ) -> MeasurementOverlay? {
        guard sharedWindow else { return nil }
        let a = anchor.frame.cg
        let b = other.frame.cg
        guard finiteAndNonEmpty(a), finiteAndNonEmpty(b) else { return nil }

        let transformed = (anchor.hasNonIdentityTransform ?? false)
                       || (other.hasNonIdentityTransform ?? false)

        let anchorRect = anchor.frame
        let otherRect = other.frame

        // Side-by-side: rects are disjoint on at least one axis.
        if !a.intersects(b) {
            return sideBySide(a: a, b: b,
                              anchorRect: anchorRect,
                              otherRect: otherRect,
                              transformed: transformed)
        }

        // Containment: whichever rect fully contains the other.
        if a.contains(b) {
            return containment(outer: a, inner: b,
                               anchorRect: anchorRect, otherRect: otherRect,
                               transformed: transformed)
        }
        if b.contains(a) {
            return containment(outer: b, inner: a,
                               anchorRect: anchorRect, otherRect: otherRect,
                               transformed: transformed)
        }

        // Remaining cases (overlap, sameView) land in Task 7.
        return nil
    }

    // MARK: side-by-side

    private static func sideBySide(
        a: CGRect, b: CGRect,
        anchorRect: CGRectCodable,
        otherRect: CGRectCodable,
        transformed: Bool
    ) -> MeasurementOverlay {
        var guides: [MeasurementGuide] = []
        var hGap: Double? = nil
        var vGap: Double? = nil

        // Horizontal gap — only if the rects are disjoint horizontally.
        if a.maxX <= b.minX {
            let gap = Double(b.minX - a.maxX)
            hGap = gap
            let y = sharedAxisMid(a1: Double(a.minY), a2: Double(a.maxY),
                                  b1: Double(b.minY), b2: Double(b.maxY))
            guides.append(.horizontal(y: y,
                                      x1: Double(a.maxX),
                                      x2: Double(b.minX),
                                      label: labelFor(gap)))
        } else if b.maxX <= a.minX {
            let gap = Double(a.minX - b.maxX)
            hGap = gap
            let y = sharedAxisMid(a1: Double(a.minY), a2: Double(a.maxY),
                                  b1: Double(b.minY), b2: Double(b.maxY))
            guides.append(.horizontal(y: y,
                                      x1: Double(b.maxX),
                                      x2: Double(a.minX),
                                      label: labelFor(gap)))
        }

        // Vertical gap — only if the rects are disjoint vertically.
        if a.maxY <= b.minY {
            let gap = Double(b.minY - a.maxY)
            vGap = gap
            let x = sharedAxisMid(a1: Double(a.minX), a2: Double(a.maxX),
                                  b1: Double(b.minX), b2: Double(b.maxX))
            guides.append(.vertical(x: x,
                                    y1: Double(a.maxY),
                                    y2: Double(b.minY),
                                    label: labelFor(gap)))
        } else if b.maxY <= a.minY {
            let gap = Double(a.minY - b.maxY)
            vGap = gap
            let x = sharedAxisMid(a1: Double(a.minX), a2: Double(a.maxX),
                                  b1: Double(b.minX), b2: Double(b.maxX))
            guides.append(.vertical(x: x,
                                    y1: Double(b.maxY),
                                    y2: Double(a.minY),
                                    label: labelFor(gap)))
        }

        return MeasurementOverlay(
            anchor: anchorRect,
            other: otherRect,
            otherIsTransformed: transformed,
            guides: guides,
            summary: MeasurementSummary(kind: .sideBySide,
                                        horizontal: hGap,
                                        vertical: vGap)
        )
    }

    // MARK: containment

    private static func containment(
        outer: CGRect,
        inner: CGRect,
        anchorRect: CGRectCodable,
        otherRect: CGRectCodable,
        transformed: Bool
    ) -> MeasurementOverlay {
        let top    = Double(inner.minY - outer.minY)
        let right  = Double(outer.maxX - inner.maxX)
        let bottom = Double(outer.maxY - inner.maxY)
        let left   = Double(inner.minX - outer.minX)

        let guides: [MeasurementGuide] = [
            .vertical(x: Double(inner.midX), y1: Double(outer.minY), y2: Double(inner.minY),
                      label: labelFor(top)),
            .horizontal(y: Double(inner.midY), x1: Double(inner.maxX), x2: Double(outer.maxX),
                        label: labelFor(right)),
            .vertical(x: Double(inner.midX), y1: Double(inner.maxY), y2: Double(outer.maxY),
                      label: labelFor(bottom)),
            .horizontal(y: Double(inner.midY), x1: Double(outer.minX), x2: Double(inner.minX),
                        label: labelFor(left)),
        ]

        return MeasurementOverlay(
            anchor: anchorRect,
            other: otherRect,
            otherIsTransformed: transformed,
            guides: guides,
            summary: MeasurementSummary(
                kind: .containment,
                horizontal: min(left, right),
                vertical: min(top, bottom)
            )
        )
    }

    // Pick the midpoint of the overlapping range on one axis; fall back to the
    // midpoint of the combined range when the rects don't overlap on that axis.
    private static func sharedAxisMid(a1: Double, a2: Double, b1: Double, b2: Double) -> Double {
        let overlapLo = max(a1, b1)
        let overlapHi = min(a2, b2)
        if overlapHi > overlapLo {
            return (overlapLo + overlapHi) / 2
        }
        return (min(a1, b1) + max(a2, b2)) / 2
    }

    private static func labelFor(_ pt: Double) -> String {
        String(Int(pt.rounded()))
    }

    private static func finiteAndNonEmpty(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite
            && r.size.width.isFinite && r.size.height.isFinite
            && r.size.width > 0 && r.size.height > 0
    }
}
