import Foundation

/// A user-space iOS Simulator app currently running on a device.
public struct RunningApp: Sendable, Equatable {
    public let pid: Int32
    public let bundleIdentifier: String
    public init(pid: Int32, bundleIdentifier: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Lists user-space UIKit apps currently running on a booted simulator by
/// parsing `xcrun simctl spawn <udid> launchctl list`. System apps
/// (`com.apple.*`) are filtered out so callers can pick the user's app
/// directly when exactly one is running.
public struct RunningAppsLocator: Sendable {
    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    private let shell: ShellExecutor

    public init(shell: ShellExecutor = SystemShellExecutor()) {
        self.shell = shell
    }

    public func listRunningUserApps(deviceUDID: String) async throws -> [RunningApp] {
        let result = try await shell.run(
            executable: Self.xcrun,
            arguments: ["simctl", "spawn", deviceUDID, "launchctl", "list"],
            environment: nil
        )
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        return Self.parse(launchctlList: stdout)
    }

    /// Public for testing. Each line looks like:
    /// `<pid>\t<status>\tUIKitApplication:<bundleID>[<hash>][<tag>]`
    /// System apps have `com.apple.` prefixes; those are filtered out.
    public static func parse(launchctlList output: String) -> [RunningApp] {
        output.split(separator: "\n").compactMap { line -> RunningApp? in
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { return nil }
            let label = columns[2]
            guard label.hasPrefix("UIKitApplication:") else { return nil }
            // Extract bundle identifier between the first `:` and the first `[`.
            let afterColon = label.dropFirst("UIKitApplication:".count)
            guard let bracket = afterColon.firstIndex(of: "[") else { return nil }
            let bundleID = String(afterColon[..<bracket])
            if bundleID.hasPrefix("com.apple.") { return nil }
            guard let pid = Int32(columns[0]) else { return nil }
            return RunningApp(pid: pid, bundleIdentifier: bundleID)
        }
    }
}
