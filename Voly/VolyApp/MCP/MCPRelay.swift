import Foundation
import VolyHost

/// `Voly --mcp`: the app's own executable, started by an AI agent as an MCP
/// server. It serves the agent over stdin/stdout and hands tool calls to
/// the running Voly; it never becomes an app itself (no window, no menu-bar
/// icon, no simulator integration).
nonisolated enum MCPRelay {
    static let flag = "--mcp"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The executable an agent should run, with its arguments.
    static var command: [String] {
        [Bundle.main.executablePath ?? CommandLine.arguments[0], flag]
    }

    static func run() -> Never {
        let bundle = Bundle.main.bundleURL
        // Tests point the helper at a scratch Voly and must not start a real one.
        let mayLaunch = ProcessInfo.processInfo.environment["VOLY_MCP_NO_LAUNCH"] != "1"
            && bundle.pathExtension == "app"
        var launch: MCPStdioRelay.Launcher?
        if mayLaunch { launch = { launchApp(at: bundle) } }
        MCPStdioRelay.run(version: appVersion, launchVoly: launch)
    }

    /// Start Voly in the background, as the user would from the Finder.
    private static func launchApp(at bundle: URL) {
        // An app started through `open` doesn't inherit this process's
        // environment. Whatever decides where Voly keeps its socket has to
        // travel, or the Voly we start would listen somewhere else.
        var forwarded = [VolyInjectionCoordinator.supportDirectoryEnvironmentKey]
        #if DEBUG
        forwarded += ["VOLY_SCRIPTED_RUN", "VOLY_SCRIPTED_SIMULATORS"]
        #endif
        let environment = ProcessInfo.processInfo.environment
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g"]
            + forwarded.flatMap { key in environment[key].map { ["--env", "\(key)=\($0)"] } ?? [] }
            + [bundle.path]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
    }

    // MARK: - What the user pastes into their agent

    private static func shellQuoted(_ text: String) -> String {
        let safe = text.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return safe ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var claudeCodeSetupCommand: String {
        "claude mcp add --scope user voly -- " + command.map(shellQuoted).joined(separator: " ")
    }

    static var codexSetupCommand: String {
        "codex mcp add voly -- " + command.map(shellQuoted).joined(separator: " ")
    }

    /// The `mcpServers` entry most other clients (Cursor, Claude Desktop,
    /// Windsurf, …) take in their MCP settings file.
    static var genericConfiguration: String {
        let entry: [String: Any] = ["mcpServers": ["voly": ["command": command[0], "args": Array(command.dropFirst())]]]
        let data = (try? JSONSerialization.data(
            withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
