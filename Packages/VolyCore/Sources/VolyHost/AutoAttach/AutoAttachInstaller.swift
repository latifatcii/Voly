import Foundation

/// Installs `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` at the user-session level
/// via `launchctl setenv`. Every subsequent simctl-driven simulator launch
/// inherits the var and loads `VolyAgent.dylib` before the app's main runs.
public struct AutoAttachInstaller: Sendable {
    public enum State: Equatable, Sendable {
        case enabled(dylibPath: String)
        case disabled
        case foreign(currentValue: String)
    }

    public static let envVarName = "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"
    private static let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    public let bundledDylibPath: String
    private let shell: ShellExecutor

    public init(bundledDylibPath: String, shell: ShellExecutor = SystemShellExecutor()) {
        self.bundledDylibPath = bundledDylibPath
        self.shell = shell
    }

    public func currentState() async throws -> State {
        let result = try await shell.run(
            executable: Self.launchctl,
            arguments: ["getenv", Self.envVarName],
            environment: nil
        )
        let raw = String(data: result.stdout, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .disabled }
        if trimmed == bundledDylibPath { return .enabled(dylibPath: trimmed) }
        return .foreign(currentValue: trimmed)
    }

    /// Idempotent: if already enabled with our path, does nothing. Otherwise
    /// calls `launchctl setenv` to set (or overwrite) the var.
    public func ensureInstalled() async throws {
        let state = try await currentState()
        if case .enabled = state { return }
        _ = try await shell.run(
            executable: Self.launchctl,
            arguments: ["setenv", Self.envVarName, bundledDylibPath],
            environment: nil
        )
    }

    public func uninstall() async throws {
        _ = try await shell.run(
            executable: Self.launchctl,
            arguments: ["unsetenv", Self.envVarName],
            environment: nil
        )
    }
}
