#if canImport(UIKit)
import Foundation
import Network
import OSLog
#if !VOLY_UNIFIED_BUILD
import VolyProtocol
#endif

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.VolyAgent", category: "WebSocketServer")

/// WebSocket server using Network.framework. Advertises over Bonjour as
/// `_voly-agent._tcp` and serves at most one client at a time (MVP).
///
/// Each accepted connection gets a fresh `connectionID`, carried on every
/// incoming message, so the runtime can tie authentication to the connection
/// that performed it and never answer a command on behalf of a previous one.
public actor WebSocketServer {
    public struct Incoming: Sendable {
        public let envelope: MessageEnvelope
        public let connectionID: UInt64
    }

    public enum ServerError: Error {
        case notListening
        case writeFailed(Error)
        case closed
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var connectionID: UInt64 = 0
    private var readyPort: UInt16?
    private var loopbackOnly = false
    private var continuation: AsyncStream<Incoming>.Continuation?
    public nonisolated let incoming: AsyncStream<Incoming>
    private let serviceName: String
    private let serviceType = ProtocolVersion.bonjourServiceType

    public init(serviceName: String) {
        self.serviceName = serviceName
        var cont: AsyncStream<Incoming>.Continuation!
        self.incoming = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// - Parameter loopbackOnly: bind to 127.0.0.1 and drop any peer that is
    ///   not local. Used for injected simulator agents, which are only ever
    ///   reached from the Mac that hosts the simulator.
    public func start(preferredPort: UInt16 = 0, advertise: Bool = true, loopbackOnly: Bool = false) throws {
        let params = NWParameters(tls: nil)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let port: NWEndpoint.Port = preferredPort == 0 ? .any : (NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        let listener: NWListener
        if loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: port)
        }
        self.loopbackOnly = loopbackOnly
        if advertise {
            listener.service = NWListener.Service(name: serviceName, type: serviceType)
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { await self.accept(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            log.info("listener state: \(String(describing: state), privacy: .public)")
            if case .ready = state, let port = listener.port {
                log.notice("VolyAgent LISTENING ON PORT \(port.rawValue, privacy: .public)")
                guard let self else { return }
                Task { await self.listenerBecameReady(port: port.rawValue) }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        log.info("WebSocketServer started with service \(self.serviceName, privacy: .public)")
    }

    private func listenerBecameReady(port: UInt16) {
        readyPort = port == 0 ? nil : port
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        continuation?.finish()
    }

    /// The port the listener is accepting on, once it is actually ready.
    /// `NWListener.port` reads 0 before that, which must never be published.
    public var boundPort: UInt16? { readyPort }

    /// Close the current client, e.g. after a failed authentication.
    public func dropConnection(_ id: UInt64) {
        guard id == connectionID else { return }
        connection?.cancel()
        connection = nil
    }

    /// Send to the current client. Pass `connectionID` for replies so a
    /// response is never delivered to a client that connected afterwards.
    public func send(_ envelope: MessageEnvelope, to connectionID: UInt64? = nil) async throws {
        if let connectionID, connectionID != self.connectionID {
            throw ServerError.closed
        }
        guard let connection else {
            log.error("send called with no connection")
            throw ServerError.closed
        }
        let data = try Framing.encodeEnvelope(envelope)
        log.info("sending envelope id=\(envelope.id) kind=\(String(describing: envelope.kind), privacy: .public) bytes=\(data.count, privacy: .public)")
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "voly", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        log.error("send error: \(String(describing: error), privacy: .public)")
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    private func accept(_ connection: NWConnection) {
        if loopbackOnly, !Self.isLoopback(connection.endpoint) {
            log.error("rejecting non-loopback peer")
            connection.cancel()
            return
        }
        log.info("accepting new connection")
        self.connection?.cancel()
        self.connection = connection
        connectionID &+= 1
        let id = connectionID
        connection.stateUpdateHandler = { [weak self] state in
            log.info("connection state: \(String(describing: state), privacy: .public)")
            guard let self else { return }
            Task { await self.stateChanged(state, connectionID: id) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(on: connection, connectionID: id)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }

    private func stateChanged(_ state: NWConnection.State, connectionID id: UInt64) {
        switch state {
        case .cancelled, .failed:
            // A late callback from a replaced connection must not clear its
            // successor.
            if id == connectionID { connection = nil }
        default: break
        }
    }

    private nonisolated func receiveLoop(on connection: NWConnection, connectionID id: UInt64) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                log.error("receive error: \(String(describing: error), privacy: .public)")
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                log.info("received \(data.count, privacy: .public) bytes")
                do {
                    let envelope = try Framing.decodeEnvelope(data)
                    log.info("decoded envelope id=\(envelope.id) kind=\(String(describing: envelope.kind), privacy: .public)")
                    Task { await self.yield(envelope, connectionID: id) }
                } catch {
                    log.error("decode error: \(String(describing: error), privacy: .public)")
                }
            }
            if isComplete, data == nil {
                log.info("peer closed")
                connection.cancel()
                return
            }
            self.receiveLoop(on: connection, connectionID: id)
        }
    }

    private func yield(_ envelope: MessageEnvelope, connectionID id: UInt64) {
        continuation?.yield(Incoming(envelope: envelope, connectionID: id))
    }
}
#endif
