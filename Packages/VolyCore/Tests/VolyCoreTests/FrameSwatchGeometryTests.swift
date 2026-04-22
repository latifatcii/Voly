import XCTest
@testable import VolyModels

final class FrameSwatchGeometryTests: XCTestCase {
    let cell = CGRect(x: 0, y: 0, width: 48, height: 48)

    func test_centered_child_fills_half_when_parent_is_2x() {
        let parent = CGRect(x: 0, y: 0, width: 200, height: 200)
        let child = CGRect(x: 50, y: 50, width: 100, height: 100)
        let r = FrameSwatchGeometry.swatchRect(child: child, parent: parent, cell: cell)
        XCTAssertEqual(r.width, 24, accuracy: 0.01)
        XCTAssertEqual(r.height, 24, accuracy: 0.01)
        XCTAssertEqual(r.minX, 12, accuracy: 0.01)
        XCTAssertEqual(r.minY, 12, accuracy: 0.01)
    }

    func test_zero_parent_yields_empty_rect() {
        let r = FrameSwatchGeometry.swatchRect(
            child: CGRect(x: 0, y: 0, width: 10, height: 10),
            parent: .zero,
            cell: cell
        )
        XCTAssertEqual(r, .zero)
    }

    func test_child_overflowing_parent_clamps_into_cell() {
        let parent = CGRect(x: 0, y: 0, width: 100, height: 100)
        let child = CGRect(x: -50, y: -50, width: 200, height: 200)
        let r = FrameSwatchGeometry.swatchRect(child: child, parent: parent, cell: cell)
        XCTAssertGreaterThanOrEqual(r.minX, 0)
        XCTAssertGreaterThanOrEqual(r.minY, 0)
        XCTAssertLessThanOrEqual(r.maxX, 48)
        XCTAssertLessThanOrEqual(r.maxY, 48)
    }

    func test_nan_input_yields_empty_rect() {
        let parent = CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)
        let child = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(
            FrameSwatchGeometry.swatchRect(child: child, parent: parent, cell: cell),
            .zero
        )
    }
}
