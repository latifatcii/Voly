import Foundation

/// Legacy mechanism, kept only so it can be cleaned up.
///
/// Older Voly builds set `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` for the whole
/// user session via `launchctl setenv`. That reached every simulator and
/// every simctl launch on the Mac and still missed Xcode's debug launches.
/// Per-simulator integration (`VolyInjectionCoordinator`) replaces it; Voly
/// now only calls `removeLegacyInstall()` on start.
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

    /// Unset the session-wide variable if (and only if) a Voly build set it.
    /// A value some other tool put there is left alone. Returns true when
    /// something was removed.
    @discardableResult
    public func removeLegacyInstall() async throws -> Bool {
        switch try await currentState() {
        case .enabled:
            try await uninstall()
            return true
        case .foreign(let value) where value.hasSuffix("/VolyAgent.dylib"):
            // A previous Voly.app location or build.
            try await uninstall()
            return true
        case .foreign, .disabled:
            return false
        }
    }

    public func uninstall() async throws {
        _ = try await shell.run(
            executable: Self.launchctl,
            arguments: ["unsetenv", Self.envVarName],
            environment: nil
        )
    }
}
