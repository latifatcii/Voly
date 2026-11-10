import XCTest
@testable import VolyHost

final class SimulatorWindowPickerTests: XCTestCase {
    private let simulator: pid_t = 90583
    private let other: pid_t = 111

    private func window(_ pid: pid_t, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        layer: Int = 0, alpha: Double = 1) -> OnScreenWindow {
        OnScreenWindow(ownerPID: pid, layer: layer, alpha: alpha, bounds: CGRect(x: x, y: y, width: w, height: h))
    }

    func test_picks_the_device_window_that_is_in_front() {
        // Shape of a real Simulator session: title strips, two devices, the
        // Apple TV remote. The 17 Pro was focused last, so it is listed first.
        let windows = [
            window(other, 0, 0, 1728, 1084),                 // some other app in front of everything
            window(simulator, 0, 0, 1728, 33),               // title strip
            window(simulator, 551, 33, 456, 972),            // iPhone 17 Pro (front)
            window(simulator, 95, 55, 456, 972),             // iPhone 16 Pro
            window(simulator, 1321, 102, 155, 515),          // Apple TV Remote
        ]
        let picked = SimulatorWindowPicker.frontmostDeviceWindow(in: windows, simulatorPID: simulator)
        XCTAssertEqual(picked?.bounds, CGRect(x: 551, y: 33, width: 456, height: 972))
    }

    func test_follows_focus_when_the_other_simulator_comes_forward() {
        let windows = [
            window(simulator, 95, 55, 456, 972),             // iPhone 16 Pro now in front
            window(simulator, 551, 33, 456, 972),
        ]
        let picked = SimulatorWindowPicker.frontmostDeviceWindow(in: windows, simulatorPID: simulator)
        XCTAssertEqual(picked?.bounds.minX, 95)
    }

    func test_accepts_landscape_and_scaled_down_devices() {
        XCTAssertNotNil(SimulatorWindowPicker.frontmostDeviceWindow(
            in: [window(simulator, 0, 0, 972, 456)], simulatorPID: simulator))
        XCTAssertNotNil(SimulatorWindowPicker.frontmostDeviceWindow(
            in: [window(simulator, 0, 0, 228, 486)], simulatorPID: simulator))
    }

    func test_ignores_windows_that_are_not_devices() {
        let windows = [
            window(simulator, 0, 0, 1728, 33),               // title strip
            window(simulator, 1321, 102, 155, 515),          // Apple TV Remote
            window(simulator, 0, 0, 456, 972, layer: 25),    // not a normal-level window
            window(simulator, 0, 0, 456, 972, alpha: 0),     // invisible
            window(other, 0, 0, 456, 972),                   // right size, wrong app
        ]
        XCTAssertNil(SimulatorWindowPicker.frontmostDeviceWindow(in: windows, simulatorPID: simulator))
    }

    func test_cocoa_frame_flips_the_vertical_axis() {
        let frame = SimulatorWindowPicker.cocoaFrame(
            for: CGRect(x: 551, y: 33, width: 456, height: 972), primaryScreenHeight: 1117)
        XCTAssertEqual(frame, CGRect(x: 551, y: 112, width: 456, height: 972))
    }
}
