import Darwin
import Foundation

/// MCP's stdio transport: one JSON message per line on stdin, replies one
/// per line on stdout.
public enum MCPStdio {
    /// Serves stdin until it closes, then exits.
    public static func serve(_ server: MCPServer) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let output = Output()
        let inFlight = DispatchGroup()
        let reader = LineReader(fd: STDIN_FILENO, limit: 8 << 20)
        while let line = try? reader.next() {
            guard line.contains(where: { !MCPSocketListener.whitespace.contains($0) }) else { continue }
            inFlight.enter()
            Task {
                if let reply = await server.handle(line: line) { output.write(reply) }
                inFlight.leave()
            }
        }
        // The client closed stdin: let calls already running finish (one
        // may be waiting for Voly to start).
        _ = inFlight.wait(timeout: .now() + 60)
        exit(0)
    }

    /// Replies can finish in any order; each must reach stdout whole.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()

        func write(_ line: Data) {
            lock.lock()
            defer { lock.unlock() }
            var data = line
            data.append(0x0A)
            // Nobody is reading any more: nothing left to serve.
            if (try? UnixSocket.write(data, to: STDOUT_FILENO)) == nil { exit(0) }
        }
    }
}

/// The process an AI agent starts to reach Voly (`Voly --mcp`).
///
/// It speaks MCP on stdin/stdout itself — so connecting and listing tools
/// always works, whether or not Voly is running — and passes each tool call
/// on to the running Voly over its socket. If Voly isn't running when the
/// first tool is called, it is started then; merely having the server
/// configured never launches it.
public enum MCPStdioRelay {
    public typealias Launcher = @Sendable () -> Void

    public static func server(
        socketPath: String = MCPEndpoint.socketPath,
        version: String,
        launchVoly: Launcher?
    ) -> MCPServer {
        MCPServer(
            name: "voly", title: "Voly", version: version,
            instructions: MCPToolbox.instructions,
            provider: RelayToolProvider(socketPath: socketPath, launchVoly: launchVoly)
        )
    }

    /// Serves stdin until it closes, then exits.
    public static func run(
        socketPath: String = MCPEndpoint.socketPath,
        version: String,
        launchVoly: Launcher?
    ) -> Never {
        MCPStdio.serve(server(socketPath: socketPath, version: version, launchVoly: launchVoly))
    }
}

/// Offers Voly's tools and forwards each call to the running app.
struct RelayToolProvider: MCPToolProviding {
    let socketPath: String
    let launchVoly: MCPStdioRelay.Launcher?
    /// How long a freshly started Voly gets to open its socket.
    var launchTimeout: TimeInterval = 25

    var tools: [MCPTool] { MCPToolbox.definitions }

    func call(_ name: String, arguments: JSONValue) async -> MCPToolResult? {
        guard tools.contains(where: { $0.name == name }) else { return nil }
        let request: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": .string(name), "arguments": arguments],
        ]
        // Socket I/O blocks; keep it off the concurrency pool's threads.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: forward(request.encoded()))
            }
        }
    }

    private func forward(_ line: Data) -> MCPToolResult {
        guard waitForVoly() else {
            return .error(launchVoly == nil
                ? "Voly isn't running. Open Voly (it lives in the menu bar), then try again."
                : "Voly isn't running and didn't start in time. Open Voly (it lives in the menu bar), then try again.")
        }
        do {
            let reply = try JSONValue.parse(MCPSocketClient.roundTrip(line, path: socketPath))
            if let result = reply["result"].flatMap(MCPToolResult.init(json:)) { return result }
            return .error(reply["error"]?["message"]?.stringValue ?? "Voly gave an unexpected answer.")
        } catch {
            return .error("Lost the connection to Voly (\(error.localizedDescription)). Is it still running?")
        }
    }

    /// True once Voly is listening, starting it first if need be.
    private func waitForVoly() -> Bool {
        if MCPSocketClient.isListening(at: socketPath) { return true }
        guard let launchVoly else { return false }
        Self.launchOnce.run(launchVoly)
        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            usleep(250_000)
            if MCPSocketClient.isListening(at: socketPath) { return true }
        }
        return false
    }

    /// Several tool calls can arrive together; Voly is started for the first
    /// and the rest wait for the same launch. A later call may try again
    /// (the user might have quit it meanwhile), but not more often than
    /// every few seconds.
    private static let launchOnce = LaunchThrottle()

    private final class LaunchThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Date?

        func run(_ launch: MCPStdioRelay.Launcher) {
            lock.lock()
            let due = last.map { Date().timeIntervalSince($0) > 30 } ?? true
            if due { last = Date() }
            lock.unlock()
            if due { launch() }
        }
    }
}
