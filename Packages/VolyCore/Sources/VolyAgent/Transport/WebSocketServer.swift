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
public actor WebSocketServer {
    public enum ServerError: Error {
        case notListening
        case writeFailed(Error)
        case closed
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var continuation: AsyncStream<MessageEnvelope>.Continuation?
    public nonisolated let incoming: AsyncStream<MessageEnvelope>
    private let serviceName: String
    private let serviceType = ProtocolVersion.bonjourServiceType

    public init(serviceName: String) {
        self.serviceName = serviceName
        var cont: AsyncStream<MessageEnvelope>.Continuation!
        self.incoming = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start(preferredPort: UInt16 = 0, advertise: Bool = true) throws {
        let params = NWParameters(tls: nil)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let port: NWEndpoint.Port = preferredPort == 0 ? .any : (NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        let listener = try NWListener(using: params, on: port)
        if advertise {
            listener.service = NWListener.Service(name: serviceName, type: serviceType)
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { await self.accept(conn) }
        }
        listener.stateUpdateHandler = { state in
            log.info("listener state: \(String(describing: state), privacy: .public)")
            if case .ready = state, let port = listener.port {
                log.notice("VolyAgent LISTENING ON PORT \(port.rawValue, privacy: .public)")
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        log.info("WebSocketServer started with service \(self.serviceName, privacy: .public)")
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        continuation?.finish()
    }

    public var boundPort: UInt16? {
        guard let port = listener?.port else { return nil }
        return port.rawValue
    }

    public func send(_ envelope: MessageEnvelope) async throws {
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
        log.info("accepting new connection")
        self.connection?.cancel()
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            log.info("connection state: \(String(describing: state), privacy: .public)")
            guard let self else { return }
            Task { await self.stateChanged(state) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(on: connection)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .cancelled: connection = nil
        default: break
        }
    }

    private nonisolated func receiveLoop(on connection: NWConnection) {
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
                    Task { await self.yield(envelope) }
                } catch {
                    log.error("decode error: \(String(describing: error), privacy: .public)")
                }
            }
            if isComplete, data == nil {
                log.info("peer closed")
                connection.cancel()
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    private func yield(_ envelope: MessageEnvelope) {
        continuation?.yield(envelope)
    }
}
#endif
