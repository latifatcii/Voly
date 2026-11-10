#if canImport(AppKit)
import XCTest
@testable import VolyHost

final class InspectorLayeringTests: XCTestCase {
    private let voly: pid_t = 1
    private let simulator: pid_t = 10
    private let emulator: pid_t = 11
    private let editor: pid_t = 20
    private let browser: pid_t = 21

    private func window(_ owner: pid_t, _ number: Int, width: CGFloat = 400, height: CGFloat = 900, layer: Int = 0) -> OnScreenWindow {
        OnScreenWindow(
            ownerPID: owner, layer: layer, alpha: 1, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            number: number
        )
    }

    private func placement(_ windows: [OnScreenWindow], frontmost: pid_t?) -> InspectorLayering.Placement {
        InspectorLayering.placement(
            windows: windows, inspector: 1, frontmostPID: frontmost, devicePIDs: [simulator, emulator], ownPID: voly
        )
    }

    func test_it_floats_while_a_device_window_or_voly_itself_is_in_front() {
        let windows = [window(voly, 1), window(simulator, 2), window(editor, 3)]
        let inFront = InspectorLayering.Placement(floats: true, order: .front)
        XCTAssertEqual(placement(windows, frontmost: simulator), inFront)
        XCTAssertEqual(placement(windows, frontmost: emulator), inFront)
        XCTAssertEqual(placement(windows, frontmost: voly), inFront)
        XCTAssertEqual(placement(windows, frontmost: nil), inFront)
    }

    func test_behind_another_app_it_stays_just_above_the_device_window() {
        // The editor came to the front; the simulator is now under the browser too.
        let windows = [window(voly, 1), window(editor, 3), window(browser, 4), window(simulator, 2)]
        XCTAssertEqual(placement(windows, frontmost: editor), .init(floats: false, order: .above(2)))
    }

    func test_the_device_window_followed_is_the_frontmost_one() {
        let windows = [window(voly, 1), window(editor, 3), window(emulator, 5), window(simulator, 2)]
        XCTAssertEqual(placement(windows, frontmost: editor), .init(floats: false, order: .above(5)))
    }

    func test_toolbars_menus_and_small_windows_of_a_device_app_are_not_followed() {
        let windows = [
            window(voly, 1),
            window(editor, 3),
            window(emulator, 6, width: 54, height: 506),      // the emulator's button strip
            window(simulator, 7, layer: 25),                  // a menu
            window(emulator, 5),
        ]
        XCTAssertEqual(placement(windows, frontmost: editor), .init(floats: false, order: .above(5)))
    }

    func test_with_no_device_window_it_goes_under_the_app_in_front() {
        let windows = [window(voly, 1), window(editor, 3), window(browser, 4)]
        XCTAssertEqual(placement(windows, frontmost: editor), .init(floats: false, order: .below(3)))
        // An app with no window on this screen: nothing to go under.
        XCTAssertEqual(
            placement([window(voly, 1), window(browser, 4)], frontmost: editor), .init(floats: false, order: nil)
        )
    }

    func test_on_another_desktop_it_is_not_moved_next_to_a_window_here() {
        // The windows on screen are another desktop's: the inspector is not among them.
        let here = [window(editor, 3), window(simulator, 2)]
        XCTAssertEqual(placement(here, frontmost: editor), .init(floats: false, order: nil))
        XCTAssertEqual(placement(here, frontmost: simulator), .init(floats: true, order: nil))
    }
}
#endif
