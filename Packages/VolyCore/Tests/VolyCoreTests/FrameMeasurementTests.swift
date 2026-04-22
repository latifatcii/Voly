import XCTest
@testable import VolyModels
@testable import VolyCodables

final class FrameMeasurementTests: XCTestCase {
    // Helper: build a ViewNode with just a frame (other fields default).
    private func node(id: ObjectID, frame: CGRect, transformed: Bool = false) -> ViewNode {
        ViewNode(
            id: id, className: "UIView", moduleName: nil,
            accessibilityIdentifier: nil, owningViewControllerID: nil,
            frame: CGRectCodable(frame),
            bounds: CGRectCodable(CGRect(origin: .zero, size: frame.size)),
            center: CGPointCodable(CGPoint(x: frame.midX, y: frame.midY)),
            isHidden: false, alpha: 1,
            layer: LayerProps(cornerRadius: 0, borderWidth: 0, borderColor: nil,
                              shadowColor: nil, shadowOpacity: 0, shadowRadius: 0,
                              shadowOffset: CGSizeCodable(.zero), masksToBounds: false,
                              shouldRasterize: false, rasterizationScale: 1,
                              opacity: 1, isOpaque: false,
                              backgroundColor: nil, contentsScale: 1),
            tintColor: nil, clipsToBounds: false, contentMode: 0,
            constraintIDs: [], childIDs: [], childrenInline: nil,
            classInheritance: nil,
            hasNonIdentityTransform: transformed
        )
    }

    // MARK: side-by-side

    func test_sideBySide_horizontal_only_vertically_overlapping() {
        // anchor at x=[0,100], y=[0,100]; other at x=[150,250], y=[0,100] — same y range.
        let a = node(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = node(id: 2, frame: CGRect(x: 150, y: 0, width: 100, height: 100))
        let result = FrameMeasurement.compute(anchor: a, other: b, sharedWindow: true)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.summary.kind, .sideBySide)
        XCTAssertEqual(result?.summary.horizontal, 50)
        XCTAssertNil(result?.summary.vertical)

        // Exactly one horizontal guide, no vertical.
        XCTAssertEqual(result?.guides.count, 1)
        if case .horizontal(let y, let x1, let x2, let label) = result!.guides[0] {
            XCTAssertEqual(y, 50, accuracy: 0.01)          // mid of vertical overlap [0,100]
            XCTAssertEqual(x1, 100, accuracy: 0.01)        // right edge of anchor
            XCTAssertEqual(x2, 150, accuracy: 0.01)        // left edge of other
            XCTAssertEqual(label, "50")
        } else {
            XCTFail("expected horizontal guide, got \(result!.guides[0])")
        }
    }

    func test_sideBySide_vertical_only_horizontally_overlapping() {
        let a = node(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = node(id: 2, frame: CGRect(x: 0, y: 150, width: 100, height: 100))
        let result = FrameMeasurement.compute(anchor: a, other: b, sharedWindow: true)
        XCTAssertEqual(result?.summary.kind, .sideBySide)
        XCTAssertNil(result?.summary.horizontal)
        XCTAssertEqual(result?.summary.vertical, 50)
        XCTAssertEqual(result?.guides.count, 1)
        if case .vertical(let x, let y1, let y2, let label) = result!.guides[0] {
            XCTAssertEqual(x, 50, accuracy: 0.01)
            XCTAssertEqual(y1, 100, accuracy: 0.01)
            XCTAssertEqual(y2, 150, accuracy: 0.01)
            XCTAssertEqual(label, "50")
        } else {
            XCTFail("expected vertical guide")
        }
    }

    func test_sideBySide_diagonal_has_both_guides() {
        // anchor at (0,0,100,100); other at (200,200,100,100). Disjoint both axes.
        let a = node(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = node(id: 2, frame: CGRect(x: 200, y: 200, width: 100, height: 100))
        let result = FrameMeasurement.compute(anchor: a, other: b, sharedWindow: true)
        XCTAssertEqual(result?.summary.kind, .sideBySide)
        XCTAssertEqual(result?.summary.horizontal, 100)
        XCTAssertEqual(result?.summary.vertical, 100)
        XCTAssertEqual(result?.guides.count, 2)
    }

    func test_sideBySide_anchor_to_right_of_other_still_works() {
        // other is to the LEFT of anchor — we don't care which is left/right,
        // the gap should still be positive.
        let a = node(id: 1, frame: CGRect(x: 200, y: 0, width: 100, height: 100))
        let b = node(id: 2, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let result = FrameMeasurement.compute(anchor: a, other: b, sharedWindow: true)
        XCTAssertEqual(result?.summary.horizontal, 100)
        XCTAssertNil(result?.summary.vertical)
    }

    // MARK: containment

    func test_containment_other_inside_anchor_emits_4_insets() {
        // anchor [0..200, 0..200], other [20..180, 30..175]
        // insets: top=30, right=20, bottom=25, left=20
        let a = node(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let b = node(id: 2, frame: CGRect(x: 20, y: 30, width: 160, height: 145))
        let result = FrameMeasurement.compute(anchor: a, other: b, sharedWindow: true)
        XCTAssertEqual(result?.summary.kind, .containment)
        XCTAssertEqual(result?.guides.count, 4)

        // summary takes the minimum inset per axis
        XCTAssertEqual(result?.summary.horizontal, 20)   // min(left=20, right=20) = 20
        XCTAssertEqual(result?.summary.vertical, 25)     // min(top=30, bottom=25) = 25

        // Collect guide labels for easy assertion; order is top, right, bottom, left.
        let labels = result!.guides.map { g -> String in
            switch g {
            case .horizontal(_, _, _, let l): return l
            case .vertical(_, _, _, let l): return l
            }
        }
        XCTAssertTrue(labels.contains("30"))   // top
        XCTAssertTrue(labels.contains("20"))   // right
        XCTAssertTrue(labels.contains("25"))   // bottom
        XCTAssertTrue(labels.contains("20"))   // left
    }

    func test_containment_anchor_inside_other_also_emits_4_insets() {
        // Reverse containment still produces 4 guides measuring the inner rect.
        let a = node(id: 1, frame: CGRect(x: 20, y: 30, width: 160, height: 145))
        let b = node(id: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let result = FrameMeasurement.compute(anchor: a, other: b, sharedWindow: true)
        XCTAssertEqual(result?.summary.kind, .containment)
        XCTAssertEqual(result?.guides.count, 4)
    }
}
