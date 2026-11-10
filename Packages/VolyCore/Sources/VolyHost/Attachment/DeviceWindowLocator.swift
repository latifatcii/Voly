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
