import Foundation
import Observation
import OSLog
import VolyHost
import VolyModels
import VolyProtocol

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "MCP")

/// Lets AI agents see what Voly sees.
///
/// Voly listens on a socket in the user's Library; an agent starts
/// `Voly --mcp` (see `MCPRelay`), which speaks the Model Context Protocol
/// with the agent and passes its tool calls here. The tools run on top of
/// the inspector session, so an agent talks to the same apps over the same
/// connections as the window does — nothing is opened to the network.
@MainActor
@Observable
final class MCPService {
    static let enabledKey = "voly.mcp.enabled"
    static let changesKey = "voly.mcp.allowChanges"

    struct ToolCall: Equatable {
        let name: String
        let date: Date
    }

    /// Agents may read from apps at all.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    /// Agents may also change the running app (properties, constraints,
    /// navigation, language, defaults, relaunch).
    var allowsChanges: Bool {
        didSet { defaults.set(allowsChanges, forKey: Self.changesKey) }
    }
    private(set) var lastToolCall: ToolCall?
    private(set) var toolCallCount = 0
    /// Why agents can't reach this Voly, when the socket couldn't be opened.
    private(set) var listenError: String?

    private let defaults: UserDefaults
    private weak var session: InspectorSession?
    private var listener: MCPSocketListener?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Both on unless the user said otherwise.
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        allowsChanges = defaults.object(forKey: Self.changesKey) as? Bool ?? true
    }

    var access: MCPAccess {
        guard isEnabled else { return .off }
        return allowsChanges ? .full : .readOnly
    }

    func start(session: InspectorSession) {
        guard listener == nil else { return }
        self.session = session
        let server = MCPServer(
            name: "voly", title: "Voly", version: MCPRelay.appVersion,
            instructions: MCPToolbox.instructions,
            provider: MCPToolbox(inspector: MCPSessionBridge(service: self, session: session))
        )
        let listener = MCPSocketListener { line in await server.handle(line: line) }
        do {
            try listener.start()
            self.listener = listener
            listenError = nil
            log.notice("listening for AI agents on \(listener.path, privacy: .public)")
        } catch {
            listenError = error.localizedDescription
            log.error("could not listen for AI agents: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    #if DEBUG
    /// UI previews only: look as if an agent had just called a tool.
    func setPreview(lastToolCall name: String) {
        lastToolCall = ToolCall(name: name, date: Date())
        toolCallCount = 1
    }
    #endif

    fileprivate func note(_ name: String) {
        lastToolCall = ToolCall(name: name, date: Date())
        toolCallCount += 1
        log.info("tool call: \(name, privacy: .public)")
    }
}

/// `MCPInspecting` on top of the live inspector session.
@MainActor
private final class MCPSessionBridge: MCPInspecting {
    private weak var service: MCPService?
    private weak var session: InspectorSession?

    init(service: MCPService, session: InspectorSession) {
        self.service = service
        self.session = session
    }

    var access: MCPAccess {
        get async { service?.access ?? .off }
    }

    func apps() async -> [MCPApp] {
        guard let session else { return [] }
        let simulators = session.simulators.simulators
        return session.connections.peers.map { peer in
            let isShown = session.state.activePeerID == peer.id
            return MCPApp(
                id: peer.id,
                name: peer.displayName,
                bundleIdentifier: peer.bundleIdentifier ?? (isShown ? session.state.agent?.bundleIdentifier : nil),
                pid: peer.pid,
                simulatorUDID: peer.deviceUDID,
                simulatorName: peer.deviceUDID.flatMap { udid in simulators.first { $0.id == udid }?.device.name },
                isShownInVoly: isShown
            )
        }
    }

    func overview() async -> MCPOverview {
        guard let session else { return MCPOverview(simulators: [], apps: []) }
        await session.simulators.refreshAndWait(includingRunningApps: true)
        await session.refreshDiscovery()
        let simulators = session.simulators.simulators.map { simulator in
            MCPSimulator(
                udid: simulator.id,
                name: simulator.device.name,
                runtime: simulator.runtimeName,
                integration: Self.describe(simulator),
                isIntegrationActive: simulator.integration.isActive,
                appsWithoutAgent: simulator.runningApps.filter { !$0.isInstrumented }.map(\.bundleIdentifier)
            )
        }
        return MCPOverview(simulators: simulators, apps: await apps())
    }

    private static func describe(_ simulator: VolySimulatorManager.Simulator) -> String {
        if simulator.isBusy { return "Voly is setting up" }
        switch simulator.integration {
        case .active:
            return "apps launched here are inspectable"
        case .paused:
            return "Voly's integration is paused here"
        case .unsupported(let reason, _):
            return "not supported on this runtime (\(reason))"
        case .inactive:
            return simulator.error.map { "Voly's integration failed: \($0)" }
                ?? "Voly's integration is off for this simulator (Voly menu → Runtime Integration)"
        }
    }

    func send(_ command: Command, to appID: String) async throws -> Response {
        guard let session else { throw WebSocketClient.ClientError.notConnected }
        do {
            return try await session.send(command, toPeer: appID)
        } catch WebSocketClient.ClientError.agentError(let error) {
            // The tools phrase the app's own errors themselves.
            throw error
        } catch WebSocketClient.ClientError.notConnected {
            throw InspectorError.unavailable(
                "That app is no longer running, or its connection to Voly was lost. list_apps shows what is inspectable now."
            )
        }
    }

    func selection() async -> (appID: String, viewID: ObjectID)? {
        guard let session, let peer = session.state.activePeerID, let view = session.state.selectedViewID else {
            return nil
        }
        return (peer, view)
    }

    func select(view: ObjectID, in appID: String) async throws {
        guard let session else { throw WebSocketClient.ClientError.notConnected }
        try await session.select(view, inPeer: appID)
    }

    func appDidChange(_ appID: String) async {
        await session?.reloadAfterExternalChange(peerID: appID)
    }

    func relaunch(bundleIdentifier: String, simulatorUDID: String) async throws {
        guard let session else { throw WebSocketClient.ClientError.notConnected }
        try await session.simulators.relaunch(bundleIdentifier: bundleIdentifier, on: simulatorUDID)
    }

    func noteToolCall(_ name: String) async {
        service?.note(name)
    }
}
