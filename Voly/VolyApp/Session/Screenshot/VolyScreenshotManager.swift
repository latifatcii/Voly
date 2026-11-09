import AppKit
import Foundation
import VolyHost
import VolyModels

/// Host side of screenshots: takes full-display captures through `simctl`,
/// and delivers any capture (simulator, app, or single view) to a PNG file
/// or the clipboard at its native pixel size.
@MainActor
final class VolyScreenshotManager {
    enum Mode: Equatable {
        /// The simulator's whole display, via `simctl io screenshot`.
        case fullSimulator
        /// The app's own windows, rendered by the agent without Voly's overlays.
        case application
        case selectedView
    }

    enum Destination {
        case file
        case clipboard
    }

    struct Capture {
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    enum CaptureError: LocalizedError {
        case noSimulator
        case noSelection

        var errorDescription: String? {
            switch self {
            case .noSimulator: return "No booted simulator to capture."
            case .noSelection: return "Select a view first."
            }
        }
    }

    private static let directoryKey = "voly.screenshots.directory"
    private let simulator = SimulatorScreenshot()

    /// Where files are saved. Defaults to the Desktop, like macOS screenshots.
    var directory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: Self.directoryKey) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Self.directoryKey) }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = "Choose"
        panel.message = "Save Voly screenshots to this folder"
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
        }
    }

    // MARK: - Capture

    /// Full display via `simctl`, turned upright for the app's current
    /// interface orientation when that is known.
    func captureSimulator(udid: String, orientation: InterfaceOrientation) async throws -> Capture {
        let png = try await simulator.capturePNG(deviceUDID: udid)
        let upright = try SimulatorScreenshot.upright(png: png, orientation: orientation)
        return Capture(png: upright.png, pixelWidth: upright.pixelWidth, pixelHeight: upright.pixelHeight)
    }

    // MARK: - Deliver

    /// Returns a short status line for the inspector.
    func deliver(
        _ capture: Capture,
        mode: Mode,
        appName: String?,
        subject: String?,
        to destination: Destination
    ) throws -> String {
        let size = "\(capture.pixelWidth)×\(capture.pixelHeight)"
        switch destination {
        case .clipboard:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(capture.png, forType: .png)
            return "Copied \(size) screenshot"
        case .file:
            let name = Self.fileName(mode: mode, appName: appName, subject: subject, date: Date())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = Self.uniqueURL(in: directory, name: name)
            try capture.png.write(to: url, options: [.atomic])
            return "Saved \(url.lastPathComponent) (\(size))"
        }
    }

    /// e.g. `Voly SampleApp BadgeView 2026-11-10 at 14.03.27.png`
    static func fileName(mode: Mode, appName: String?, subject: String?, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var parts = ["Voly"]
        switch mode {
        case .fullSimulator:
            parts.append("Simulator")
        case .application:
            parts.append(appName ?? "App")
        case .selectedView:
            if let appName { parts.append(appName) }
            parts.append(subject ?? "View")
        }
        parts.append(formatter.string(from: date))
        let raw = parts.joined(separator: " ")
        let illegal = CharacterSet(charactersIn: "/:\\")
        return raw.components(separatedBy: illegal).joined(separator: "-") + ".png"
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        var url = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter).png")
            counter += 1
        }
        return url
    }
}
