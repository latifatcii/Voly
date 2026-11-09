// volyctl — drive Voly's simulator integration and agents from a terminal.
//
// A thin command-line client over the same pieces Voly.app uses
// (VolyInjectionCoordinator, the port-file discovery, the wire protocol),
// so the end-to-end path can be exercised and scripted without the UI:
//
//   volyctl integration enable <udid> --agent <dylib> --bridge <dylib>
//   volyctl integration status|disable <udid>
//   volyctl agents <udid>
//   volyctl send <udid> <bundle-id> '<command json>'      e.g. '{"navigationState":{}}'
//   volyctl screenshot <udid> <bundle-id> app|view:<id> <out.png>
//   volyctl source <udid> <bundle-id> <ClassName>

#if os(macOS)
import Foundation
import VolyHost
import VolyModels
import VolyProtocol

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Minimal agent client on URLSession's WebSocket — deliberately independent
/// of the app's Network.framework client, so it doubles as a second
/// implementation of the handshake and token check.
final class AgentClient {
    private let task: URLSessionWebSocketTask
    private var nextID: UInt64 = 1

    init(port: UInt16) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 10
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
    }

    func send(_ command: Command) async throws -> Response {
        let id = nextID
        nextID += 1
        let envelope = try Framing.encodeCommand(command, id: id)
        let data = try Framing.encodeEnvelope(envelope)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let message = try await task.receive()
            let payload: Data
            switch message {
            case .string(let text): payload = Data(text.utf8)
            case .data(let data): payload = data
            @unknown default: continue
            }
            let reply = try Framing.decodeEnvelope(payload)
            guard reply.id == id, reply.kind != .event else { continue }
            return try Framing.decodeResponse(reply)
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

func discover(udid: String, bundleID: String) throws -> DiscoveredAgent {
    let agents = PortFileWatcher().scan(deviceUDIDs: [udid]).filter { $0.bundleIdentifier == bundleID }
    guard let agent = agents.max(by: { $0.issuedAt < $1.issuedAt }) else {
        throw Failure("no Voly agent found for \(bundleID) in simulator \(udid)")
    }
    return agent
}

/// Connect + authenticate. `token: .some(nil)` omits the token on purpose.
func connect(to agent: DiscoveredAgent, token: String?? = nil) async throws -> (AgentClient, HandshakeAccepted) {
    let client = AgentClient(port: agent.port)
    let request = HandshakeRequest(
        clientName: "volyctl", clientVersion: "0.1.0", authToken: token ?? agent.token
    )
    let response = try await client.send(.handshake(request))
    guard case .handshakeAccepted(let accepted) = response else {
        client.close()
        throw Failure("handshake refused: \(describe(response))")
    }
    if let pid = accepted.pid, pid != agent.pid {
        client.close()
        throw Failure("port \(agent.port) answered as pid \(pid), expected \(agent.pid)")
    }
    return (client, accepted)
}

func describe(_ response: Response) -> String {
    if case .screenshot(let image) = response {
        return "{\"screenshot\":{\"pixelWidth\":\(image.pixelWidth),\"pixelHeight\":\(image.pixelHeight),\"scale\":\(image.scale),\"orientation\":\"\(image.orientation.rawValue)\",\"pngBytes\":\(image.png.count)}}"
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    encoder.nonConformingFloatEncodingStrategy =
        .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
    guard let data = try? encoder.encode(response) else { return "\(response)" }
    return String(decoding: data, as: UTF8.self)
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func findView(named className: String, in snapshot: HierarchySnapshot) -> ViewNode? {
    func search(_ node: ViewNode) -> ViewNode? {
        if node.className == className { return node }
        for child in node.childrenInline ?? [] {
            if let found = search(child) { return found }
        }
        return nil
    }
    for scene in snapshot.scenes {
        for window in scene.windowsInline {
            if let found = search(window) { return found }
        }
    }
    return nil
}

func run(_ arguments: [String]) async throws {
    let coordinator = VolyInjectionCoordinator(
        supportDirectory: option("--support-dir", in: arguments).map { URL(fileURLWithPath: $0) }
            ?? VolyInjectionCoordinator.defaultSupportDirectory
    )
    guard let verb = arguments.first else { throw Failure("usage: see the header of Sources/volyctl/main.swift") }
    switch verb {
    case "integration":
        guard arguments.count >= 3 else { throw Failure("usage: volyctl integration enable|disable|status <udid>") }
        let udid = arguments[2]
        switch arguments[1] {
        case "enable":
            guard let agent = option("--agent", in: arguments), let bridge = option("--bridge", in: arguments) else {
                throw Failure("enable needs --agent <VolyAgent.dylib> --bridge <VolyLaunchBridge.dylib>")
            }
            let runtime = try VolyRuntimeStager(supportDirectory: coordinator.supportDirectory).stage(
                bundledAgent: URL(fileURLWithPath: agent), bundledBridge: URL(fileURLWithPath: bridge)
            )
            var policy = InjectionPolicy()
            policy.excludedBundleIDs = option("--exclude", in: arguments)?.split(separator: ",").map(String.init) ?? []
            policy.allowedBundleIDs = option("--only", in: arguments)?.split(separator: ",").map(String.init) ?? []
            policy.includeSystemApps = arguments.contains("--system-apps")
            print(try await coordinator.enable(simulator: udid, runtime: runtime, policy: policy))
        case "disable":
            try await coordinator.disable(simulator: udid)
            print(coordinator.state(forSimulator: udid))
        case "status":
            print(coordinator.state(forSimulator: udid))
        default:
            throw Failure("unknown integration verb \(arguments[1])")
        }

    case "agents":
        guard arguments.count >= 2 else { throw Failure("usage: volyctl agents <udid>") }
        for agent in PortFileWatcher().scan(deviceUDIDs: [arguments[1]]) {
            print("\(agent.bundleIdentifier) pid=\(agent.pid) port=\(agent.port) token=\(agent.token == nil ? "none" : "present")")
        }

    case "send":
        guard arguments.count >= 4 else { throw Failure("usage: volyctl send <udid> <bundle-id> '<command json>'") }
        let agent = try discover(udid: arguments[1], bundleID: arguments[2])
        let command = try Framing.decoder.decode(Command.self, from: Data(arguments[3].utf8))
        if arguments.contains("--no-handshake") {
            // Prove an unauthenticated connection gets nothing.
            let client = AgentClient(port: agent.port)
            defer { client.close() }
            print(describe(try await client.send(command)))
            return
        }
        let token: String?? = arguments.contains("--wrong-token") ? .some("not-the-token") : nil
        let (client, _) = try await connect(to: agent, token: token)
        defer { client.close() }
        print(describe(try await client.send(command)))

    case "handshake":
        guard arguments.count >= 3 else { throw Failure("usage: volyctl handshake <udid> <bundle-id>") }
        let (client, accepted) = try await connect(to: try discover(udid: arguments[1], bundleID: arguments[2]))
        client.close()
        print(describe(.handshakeAccepted(accepted)))

    case "screenshot":
        guard arguments.count >= 5 else { throw Failure("usage: volyctl screenshot <udid> <bundle-id> app|view:<id>|view-class:<Name> <out.png>") }
        let (client, _) = try await connect(to: try discover(udid: arguments[1], bundleID: arguments[2]))
        defer { client.close() }
        let target: ScreenshotTarget
        if arguments[3] == "app" {
            target = .application
        } else if arguments[3].hasPrefix("view:"), let id = UInt64(arguments[3].dropFirst(5)) {
            target = .view(id)
        } else if arguments[3].hasPrefix("view-class:") {
            guard case .hierarchy(let snapshot) = try await client.send(.getHierarchy),
                  let node = findView(named: String(arguments[3].dropFirst(11)), in: snapshot)
            else { throw Failure("no such view class on screen") }
            target = .view(node.id)
        } else {
            throw Failure("target must be app, view:<id> or view-class:<Name>")
        }
        let response = try await client.send(.captureScreenshot(target))
        guard case .screenshot(let image) = response else { throw Failure(describe(response)) }
        try image.png.write(to: URL(fileURLWithPath: arguments[4]))
        print(describe(response))

    case "sim-screenshot":
        guard arguments.count >= 4 else { throw Failure("usage: volyctl sim-screenshot <udid> <bundle-id> <out.png>") }
        // Full display via simctl, turned upright using the app's orientation.
        let (client, _) = try await connect(to: try discover(udid: arguments[1], bundleID: arguments[2]))
        defer { client.close() }
        var orientation = InterfaceOrientation.unknown
        if case .screenInfo(let info) = try await client.send(.screenInfo) { orientation = info.orientation }
        let raw = try await SimulatorScreenshot().capturePNG(deviceUDID: arguments[1])
        let upright = try SimulatorScreenshot.upright(png: raw, orientation: orientation)
        try upright.png.write(to: URL(fileURLWithPath: arguments[3]))
        print("\(orientation.rawValue) \(upright.pixelWidth)x\(upright.pixelHeight)")

    case "source":
        guard arguments.count >= 4 else { throw Failure("usage: volyctl source <udid> <bundle-id> <ClassName>") }
        let (client, _) = try await connect(to: try discover(udid: arguments[1], bundleID: arguments[2]))
        defer { client.close() }
        guard case .hierarchy(let snapshot) = try await client.send(.getHierarchy),
              let node = findView(named: arguments[3], in: snapshot)
        else { throw Failure("no view of class \(arguments[3]) on screen") }
        guard case .sourceInfo(let info) = try await client.send(.resolveSource(objectID: node.id)) else {
            throw Failure("agent returned no source info")
        }
        for candidate in info.candidates ?? [] {
            print("candidate \(candidate.role.rawValue) \(candidate.runtimeName) probes=\(candidate.probes.count) image=\((candidate.imagePath as NSString).lastPathComponent)")
        }
        let lookup = await VolySourceNavigator().resolve(info)
        for location in lookup.locations {
            print("location \(location.path):\(location.line.map(String.init) ?? "-") [\(location.method) \(location.lineOrigin)] \(location.className)")
        }
        if let note = lookup.note { print("note \(note)") }
        if arguments.contains("--open"), let first = lookup.locations.first {
            try await VolySourceNavigator().open(first)
        }

    default:
        throw Failure("unknown command \(verb)")
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("volyctl: \(error)\n".utf8))
    exit(1)
}
#endif
