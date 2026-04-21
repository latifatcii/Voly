import Foundation

public struct SimctlLauncher {
    public enum LauncherError: Error, Equatable {
        case launchFailed(code: Int32, stderr: String)
        case couldNotParsePid(stdout: String)
    }

    public struct LaunchResult: Equatable, Sendable {
        public let deviceUDID: String
        public let bundleIdentifier: String
        public let pid: Int32
    }

    public let shell: ShellExecutor
    public let xcrunURL: URL

    public init(shell: ShellExecutor = SystemShellExecutor(),
                xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")) {
        self.shell = shell
        self.xcrunURL = xcrunURL
    }

    public func launch(deviceUDID: String,
                       bundleIdentifier: String,
                       dylibPath: URL,
                       additionalEnvironment: [String: String] = [:]) async throws -> LaunchResult {
        var env = additionalEnvironment
        env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylibPath.path
        let args = [
            "simctl", "launch", "--terminate-running-process",
            deviceUDID, bundleIdentifier,
        ]
        let result = try await shell.run(executable: xcrunURL, arguments: args, environment: env)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        guard result.exitCode == 0 else {
            throw LauncherError.launchFailed(code: result.exitCode, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIdx = trimmed.lastIndex(of: ":") else {
            throw LauncherError.couldNotParsePid(stdout: stdout)
        }
        let pidString = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        guard let pid = Int32(pidString) else {
            throw LauncherError.couldNotParsePid(stdout: stdout)
        }
        return LaunchResult(deviceUDID: deviceUDID, bundleIdentifier: bundleIdentifier, pid: pid)
    }

    public func terminate(deviceUDID: String, bundleIdentifier: String) async {
        _ = try? await shell.run(
            executable: xcrunURL,
            arguments: ["simctl", "terminate", deviceUDID, bundleIdentifier],
            environment: nil
        )
    }
}
