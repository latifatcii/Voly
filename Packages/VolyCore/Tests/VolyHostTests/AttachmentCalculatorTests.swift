import XCTest
@testable import VolyHost

final class AttachmentCalculatorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let voly = SizeSpec(
        minWidth: 360, preferredWidth: 440, maxWidth: 560, minHeight: 500
    )

    func test_right_edge_fits() {
        // Simulator at (200, 100) 400x800. Right edge = 600. 1920-600 = 1320 room.
        let sim = CGRect(x: 200, y: 100, width: 400, height: 800)
        let r = AttachmentCalculator.attach(simulatorFrame: sim, voly: voly, screen: screen, gap: 6)
        XCTAssertEqual(r.edge, .right)
        XCTAssertEqual(r.frame.origin.x, 606, accuracy: 0.01)
        XCTAssertEqual(r.frame.origin.y, 100, accuracy: 0.01)
        XCTAssertEqual(r.frame.size.width, 440, accuracy: 0.01)
        XCTAssertEqual(r.frame.size.height, 800, accuracy: 0.01)
    }

    func test_right_doesnt_fit_left_does() {
        // Simulator pushed to the right so only 300 px remain on right (< min 360).
        // 900 px on the left — plenty of room.
        let sim = CGRect(x: 1000, y: 100, width: 620, height: 800)
        let r = AttachmentCalculator.attach(simulatorFrame: sim, voly: voly, screen: screen, gap: 6)
        XCTAssertEqual(r.edge, .left)
        // Right edge of voly = sim.minX - gap = 1000 - 6 = 994. origin.x = 994 - 440 = 554.
        XCTAssertEqual(r.frame.origin.x, 554, accuracy: 0.01)
        XCTAssertEqual(r.frame.size.width, 440, accuracy: 0.01)
    }

    func test_neither_fits_falls_back_to_detached_right_half() {
        // Simulator spans almost the full screen. Neither edge has room.
        let sim = CGRect(x: 50, y: 50, width: 1820, height: 980)
        let r = AttachmentCalculator.attach(simulatorFrame: sim, voly: voly, screen: screen, gap: 6)
        XCTAssertEqual(r.edge, .detached)
        // Right-half fallback: centered in screen.maxX/2 ..< screen.maxX.
        XCTAssertGreaterThanOrEqual(r.frame.origin.x, screen.midX)
    }

    func test_no_simulator_uses_right_half_fallback() {
        let r = AttachmentCalculator.attach(simulatorFrame: nil, voly: voly, screen: screen, gap: 6)
        XCTAssertEqual(r.edge, .detached)
        XCTAssertGreaterThanOrEqual(r.frame.origin.x, screen.midX)
        XCTAssertEqual(r.frame.size.width, 440, accuracy: 0.01)
    }

    func test_height_clamps_to_min_when_simulator_too_short() {
        // Simulator is short (300 px). voly.minHeight = 500, so we expect 500.
        let sim = CGRect(x: 200, y: 100, width: 400, height: 300)
        let r = AttachmentCalculator.attach(simulatorFrame: sim, voly: voly, screen: screen, gap: 6)
        XCTAssertEqual(r.frame.size.height, 500, accuracy: 0.01)
    }

    func test_gap_is_respected() {
        let sim = CGRect(x: 200, y: 100, width: 400, height: 800)
        let r = AttachmentCalculator.attach(simulatorFrame: sim, voly: voly, screen: screen, gap: 20)
        XCTAssertEqual(r.frame.origin.x, sim.maxX + 20, accuracy: 0.01)
    }

    func test_detached_fallback_is_entirely_inside_screen() {
        let r = AttachmentCalculator.attach(
            simulatorFrame: nil, voly: voly, screen: screen, gap: 6
        )
        XCTAssertGreaterThanOrEqual(r.frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(r.frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(r.frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(r.frame.maxY, screen.maxY)
    }

    func test_simulator_origin_outside_screen_still_clamps_voly_inside() {
        // Simulator reports a global-coordinate frame that lives partly outside
        // the provided screen (multi-monitor case). Voly must still end up
        // fully inside the given screen rect.
        let sim = CGRect(x: -200, y: -50, width: 400, height: 900)
        let r = AttachmentCalculator.attach(
            simulatorFrame: sim, voly: voly, screen: screen, gap: 6
        )
        XCTAssertGreaterThanOrEqual(r.frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(r.frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(r.frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(r.frame.maxY, screen.maxY)
    }
}
