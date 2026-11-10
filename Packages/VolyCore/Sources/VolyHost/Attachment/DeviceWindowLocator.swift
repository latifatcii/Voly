#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation

/// The Android Emulator as a Mac app: a `qemu-system-…` process with no
/// bundle identifier, one window per virtual device.
public enum AndroidEmulatorApp {
    public static func isEmulator(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier != "com.apple.iphonesimulator" else { return false }
        let path = app.executableURL?.path ?? AdbLocator.executablePath(ofProcess: app.processIdentifier)
        return path.map(isEmulator(executablePath:)) ?? false
    }

    /// The Android SDK keeps the emulator's engine in
    /// `<sdk>/emulator/qemu/<host>/qemu-system-<arch>`. A QEMU from anywhere
    /// else runs somebody's other virtual machine, which is not Voly's to
    /// dock next to or to take ⌘E from.
    static func isEmulator(executablePath path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("qemu-system-") && path.contains("/emulator/qemu/")
    }

    public static func processIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter(isEmulator).map(\.processIdentifier))
    }
}

/// Where the device's display is inside an emulator window.
///
/// An emulator window without a device frame is macOS's title bar with the
/// display filling everything under it, at whatever size the window was
/// dragged to. That is recognised by its shape: under the title bar the
/// window has the display's own proportions. A window that draws a phone
/// around the display does not, and where the display sits in one can't be
/// told from the outside.
public enum AndroidEmulatorScreen {
    /// What macOS gives a window's title bar.
    static let titleBarHeight: CGFloat = 28
    static let tolerance: CGFloat = 2

    /// - Parameters:
    ///   - window: the emulator window, in any coordinates with y growing downwards.
    ///   - displaySize: the device's display, in any unit; only its proportions count.
    public static func display(inWindow window: CGRect, displaySize: CGSize) -> CGRect? {
        guard displaySize.width > 0, displaySize.height > 0, window.width > 0 else { return nil }
        let underTitleBar = CGRect(
            x: window.minX, y: window.minY + titleBarHeight,
            width: window.width, height: window.height - titleBarHeight
        )
        // The whole window too: one without a title bar that shows only the display.
        for content in [underTitleBar, window] where content.height > 0 {
            let expectedHeight = content.width * displaySize.height / displaySize.width
            if abs(expectedHeight - content.height) <= tolerance { return content }
        }
        return nil
    }

    /// The display of the frontmost emulator window (`windows` are front to
    /// back), preferring the one the cursor is over when there are several.
    static func display(
        in windows: [OnScreenWindow], emulatorPIDs: Set<pid_t>, displaySize: CGSize, cursor: CGPoint?
    ) -> CGRect? {
        let displays = windows
            .filter { emulatorPIDs.contains($0.ownerPID) && $0.layer == 0 && $0.alpha > 0 }
            .filter { min($0.bounds.width, $0.bounds.height) >= SimulatorWindowPicker.minimumShortSide }
            .compactMap { display(inWindow: $0.bounds, displaySize: displaySize) }
        if let cursor, let under = displays.first(where: { $0.contains(cursor) }) { return under }
        return displays.first
    }
}

/// The window Voly docks next to: the device window the user focused last,
/// whether that is an iOS simulator or an Android emulator.
///
/// With no emulator window on screen this is exactly `AXSimulatorLocator`.
public final class DeviceWindowLocator: SimulatorLocator, @unchecked Sendable {
    private let simulator = AXSimulatorLocator()

    public init() {}

    public func frontmostSimulatorFrame() -> CGRect? {
        let emulators = AndroidEmulatorApp.processIDs()
        guard !emulators.isEmpty else { return simulator.frontmostSimulatorFrame() }

        let windows = SimulatorWindowPicker.onScreenWindows()
        let simulatorPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.iphonesimulator"
        ).first?.processIdentifier
        guard let front = Self.frontmostDeviceWindow(in: windows, simulatorPID: simulatorPID, emulatorPIDs: emulators),
              emulators.contains(front.ownerPID)
        else {
            // A simulator is in front (or nothing usable is): the usual path.
            return simulator.frontmostSimulatorFrame()
        }
        let bounds = Self.includingToolbar(front, among: windows)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return SimulatorWindowPicker.cocoaFrame(for: bounds, primaryScreenHeight: primaryHeight)
    }

    public func iosScreenRegionInScreen() -> IosScreenBoundsOnScreen? {
        simulator.iosScreenRegionInScreen()
    }

    /// Where an emulator shows its display, in Cocoa screen coordinates,
    /// for a device whose display has `displaySize`'s proportions. Needs no
    /// Accessibility permission: window positions are public.
    ///
    /// - Parameter cursor: where the pointer is (Cocoa coordinates), to
    ///   pick the right window when several emulators are open.
    public func androidDisplayFrame(displaySize: CGSize, cursor: CGPoint? = nil) -> CGRect? {
        let emulators = AndroidEmulatorApp.processIDs()
        guard !emulators.isEmpty else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let display = AndroidEmulatorScreen.display(
            in: SimulatorWindowPicker.onScreenWindows(), emulatorPIDs: emulators, displaySize: displaySize,
            cursor: cursor.map { CGPoint(x: $0.x, y: primaryHeight - $0.y) }
        )
        return display.map { SimulatorWindowPicker.cocoaFrame(for: $0, primaryScreenHeight: primaryHeight) }
    }

    /// The first device-sized window, front to back, that belongs to the
    /// Simulator or to an emulator.
    static func frontmostDeviceWindow(
        in windows: [OnScreenWindow], simulatorPID: pid_t?, emulatorPIDs: Set<pid_t>
    ) -> OnScreenWindow? {
        windows.first { window in
            (window.ownerPID == simulatorPID || emulatorPIDs.contains(window.ownerPID))
                && window.layer == 0
                && window.alpha > 0
                && min(window.bounds.width, window.bounds.height) >= SimulatorWindowPicker.minimumShortSide
                && max(window.bounds.width, window.bounds.height) >= SimulatorWindowPicker.minimumLongSide
        }
    }

    /// The emulator keeps its button strip in a narrow window of its own,
    /// right next to the device. Docking has to clear that too.
    static func includingToolbar(_ device: OnScreenWindow, among windows: [OnScreenWindow]) -> CGRect {
        var bounds = device.bounds
        let reach = device.bounds.insetBy(dx: -70, dy: 0)
        for window in windows
        where window.ownerPID == device.ownerPID && window.layer == 0 && window.alpha > 0
            && window.bounds != device.bounds
            && window.bounds.width < 120
            && window.bounds.height <= device.bounds.height + 40
            && window.bounds.intersects(reach) {
            bounds = bounds.union(window.bounds)
        }
        return bounds
    }
}
#endif
