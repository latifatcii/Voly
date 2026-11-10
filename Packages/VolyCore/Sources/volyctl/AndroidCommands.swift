// volyctl android … — the Android side from a terminal, on the same code
// Voly.app uses (AndroidIntegration, the agent installer, the MCP tools):
//
//   volyctl android devices
//   volyctl android apps [<serial>]                 attach to debuggable apps, list them
//   volyctl android send <serial> <package> '<command json>'
//   volyctl android screenshot <serial> <package> app|view:<id>|device <out.png>
//   volyctl android mcp-direct [<serial>]           the MCP tools without Voly.app
//
// Attaching replaces the agent's previous session, so don't point this at an
// app Voly.app is inspecting: Voly's connection to it would be cut.
//
//   --agent-dir <dir>   where voly-agent.dex and friends are
//                       (default: $VOLY_ANDROID_AGENT_DIR, else Voly/AndroidAgentPayload)
//   --adb <path>        the adb to use (default: the one Voly would find)

#if os(macOS)
import Foundation
import VolyHost
import VolyModels
import VolyProtocol

/// One authenticated round trip to an Android agent.
func sendToAndroidAgent(_ endpoint: AndroidAgentEndpoint, _ command: Command) async throws -> Response {
    let client = AgentClient(port: endpoint.port)
    defer { client.close() }
    let hello = try await client.send(.handshake(
        HandshakeRequest(clientName: "volyctl", clientVersion: "0.1.0", authToken: endpoint.token)
    ))
    guard case .handshakeAccepted(let accepted) = hello else {
        throw Failure("handshake refused: \(describe(hello))")
    }
    guard accepted.isAndroid, accepted.pid == endpoint.pid else {
        throw Failure("port \(endpoint.port) answered as pid \(accepted.pid ?? -1), expected \(endpoint.pid)")
    }
    return try await client.send(command)
}

private func makeAndroidIntegration(_ arguments: [String]) throws -> AndroidIntegration {
    let adbURL: URL
    if let explicit = option("--adb", in: arguments) {
        adbURL = URL(fileURLWithPath: explicit)
    } else if let found = AdbLocator.runningServerExecutable() ?? AdbLocator.locate() {
        adbURL = found
    } else {
        throw Failure(AdbError.notFound.localizedDescription)
    }
    let directory = option("--agent-dir", in: arguments)
        ?? ProcessInfo.processInfo.environment["VOLY_ANDROID_AGENT_DIR"]
        ?? "Voly/AndroidAgentPayload"
    let payload = try AndroidAgentPayload.load(from: [URL(fileURLWithPath: directory)])
    return AndroidIntegration(adb: AdbClient(executable: adbURL), payload: payload)
}

private func androidEndpoint(
    _ integration: AndroidIntegration, serial: String, package: String
) async throws -> AndroidAgentEndpoint {
    let snapshot = await integration.refresh(wantsDevice: { _ in true }, allowsApp: { _ in true }, only: [serial])
    if let error = snapshot.error { throw Failure(error) }
    if let endpoint = snapshot.agents.first(where: { $0.package == package }) { return endpoint }
    let status = snapshot.devices.first?.apps.first { $0.package == package }
    switch status?.state {
    case .failed(let message)?: throw Failure("could not attach to \(package): \(message)")
    case .notDebuggable?: throw Failure("\(package) is not a debuggable build")
    default: throw Failure("\(package) is not running on \(serial)")
    }
}

func runAndroid(_ arguments: [String]) async throws {
    guard let verb = arguments.first else {
        throw Failure("usage: see the header of Sources/volyctl/AndroidCommands.swift")
    }
    let positional = arguments.dropFirst().prefix { !$0.hasPrefix("--") }.map { $0 }
    let integration = try makeAndroidIntegration(arguments)
    switch verb {
    case "devices", "apps":
        let only = positional.first.map { Set([$0]) }
        let snapshot = await integration.refresh(
            wantsDevice: { _ in verb == "apps" }, allowsApp: { _ in true }, only: only
        )
        if let error = snapshot.error { throw Failure(error) }
        if snapshot.devices.isEmpty { print("no Android emulator or device is online") }
        for status in snapshot.devices {
            let device = status.device
            print("\(device.serial)  \(device.displayName)  \(device.runtimeName)  \(device.abis.joined(separator: ","))"
                + (status.error.map { "  error: \($0)" } ?? ""))
            for app in status.apps {
                let endpoint = snapshot.agents.first { $0.serial == device.serial && $0.pid == app.pid }
                print("  \(app.package) pid=\(app.pid) \(app.state)"
                    + (endpoint.map { " port=\($0.port) label=\"\($0.label)\"" } ?? ""))
            }
        }
        await integration.releaseAll()

    case "send":
        guard positional.count >= 3 else { throw Failure("usage: volyctl android send <serial> <package> '<command json>'") }
        let endpoint = try await androidEndpoint(integration, serial: positional[0], package: positional[1])
        let command = try Framing.decoder.decode(Command.self, from: Data(positional[2].utf8))
        print(describe(try await sendToAndroidAgent(endpoint, command)))
        await integration.releaseAll()

    case "screenshot":
        guard positional.count >= 4 else {
            throw Failure("usage: volyctl android screenshot <serial> <package> app|view:<id>|device <out.png>")
        }
        let output = URL(fileURLWithPath: positional[3])
        if positional[2] == "device" {
            let png = try await integration.screenshot(serial: positional[0])
            try png.write(to: output)
            let size = PNGSize.read(png)
            print("device \(size?.width ?? 0)x\(size?.height ?? 0)")
            return
        }
        let endpoint = try await androidEndpoint(integration, serial: positional[0], package: positional[1])
        let target: ScreenshotTarget
        if positional[2] == "app" {
            target = .application
        } else if positional[2].hasPrefix("view:"), let id = UInt64(positional[2].dropFirst(5)) {
            target = .view(id)
        } else {
            throw Failure("target must be app, view:<id> or device")
        }
        let response = try await sendToAndroidAgent(endpoint, .captureScreenshot(target))
        guard case .screenshot(let image) = response else { throw Failure(describe(response)) }
        try image.png.write(to: output)
        print(describe(response))
        await integration.releaseAll()

    case "mcp-direct":
        MCPStdio.serve(MCPServer(
            name: "voly", title: "Voly", version: "volyctl", instructions: MCPToolbox.instructions,
            provider: MCPToolbox(inspector: AndroidDirectInspector(
                integration: integration, serials: positional.first.map { Set([$0]) }, send: sendToAndroidAgent
            ))
        ))

    default:
        throw Failure("unknown android command \(verb)")
    }
}
#endif
