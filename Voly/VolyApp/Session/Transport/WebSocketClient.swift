import Foundation
import Network
import OSLog
import VolyProtocol
import VolyModels

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "WebSocketClient")

/// WebSocket client over `Network.framework`. Connects directly to an `NWEndpoint`
/// (which is what `NWBrowser` hands us for a Bonjour service), so we stay in the
/// same network stack for discovery + resolution + WS handshake.
actor WebSocketClient {
    enum ClientError: Error, LocalizedError {
        case notConnected
        case decodeFailed(Error)
        case agentError(InspectorError)
        case unexpectedResponse
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to any VolyAgent."
            case .decodeFailed(let e): return "Decode failed: \(e.localizedDescription)"
            case .agentError(let e): return e.humanDescription
            case .unexpectedResponse: return "Unexpected response shape."
            case .connectionFailed(let s): return s
            }
        }
    }

    private var connection: NWConnection?
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Response, Error>] = [:]
    private var eventContinuation: AsyncStream<Event>.Continuation?
    nonisolated let events: AsyncStream<Event>

    init() {
        var cont: AsyncStream<Event>.Continuation!
        events = AsyncStream { cont = $0 }
        eventContinuation = cont
    }

    func connect(to endpoint: NWEndpoint) async throws {
        log.info("connect to \(String(describing: endpoint), privacy: .public)")
        let params = NWParameters(tls: nil)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setAdditionalHeaders([("Host", "voly-agent")])
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        let ready = AsyncStream<Result<Void, Error>> { cont in
            conn.stateUpdateHandler = { state in
                log.info("conn state: \(String(describing: state), privacy: .public)")
                switch state {
                case .ready: cont.yield(.success(())); cont.finish()
                case .failed(let e): cont.yield(.failure(e)); cont.finish()
                case .cancelled:
                    cont.yield(.failure(ClientError.connectionFailed("cancelled")))
                    cont.finish()
                default: break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))

        for await result in ready {
            switch result {
            case .success: break
            case .failure(let e):
                self.connection = nil
                throw e
            }
            break
        }

        receiveLoop()

        // Handshake
        let handshake = HandshakeRequest(clientName: "Voly.app", clientVersion: "0.1.0")
        let response = try await send(.handshake(handshake))
        guard case .handshakeAccepted = response else {
            throw ClientError.unexpectedResponse
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        for cont in pending.values {
            cont.resume(throwing: ClientError.notConnected)
        }
        pending.removeAll()
    }

    @discardableResult
    func send(_ command: Command) async throws -> Response {
        guard let connection else { throw ClientError.notConnected }
        let id = nextID
        nextID &+= 1
        let envelope = try Framing.encodeCommand(command, id: id)
        let data = try Framing.encodeEnvelope(envelope)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
            pending[id] = cont
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "voly", metadata: [metadata])
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        Task { await self.failPending(id: id, with: error) }
                    }
                }
            )
        }
    }

    private func failPending(id: UInt64, with error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private nonisolated func receiveLoop() {
        log.info("receiveLoop: scheduling first receive")
        Task { await self.receiveOne() }
    }

    private func receiveOne() async {
        guard let connection else {
            log.info("receiveOne: no connection")
            return
        }
        log.info("receiveOne: calling receiveMessage")
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            log.info("receiveMessage callback: bytes=\(data?.count ?? -1, privacy: .public) complete=\(isComplete, privacy: .public) err=\(String(describing: error), privacy: .public)")
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) async {
        if let error {
            log.error("receive error: \(String(describing: error), privacy: .public)")
            for cont in pending.values { cont.resume(throwing: error) }
            pending.removeAll()
            return
        }
        if let data, !data.isEmpty {
            log.info("handleReceive: decoding \(data.count, privacy: .public) bytes")
            do {
                let envelope = try Framing.decodeEnvelope(data)
                log.info("decoded envelope id=\(envelope.id) kind=\(String(describing: envelope.kind), privacy: .public)")
                switch envelope.kind {
                case .response, .error:
                    if let cont = pending.removeValue(forKey: envelope.id) {
                        do {
                            let response = try Framing.decodeResponse(envelope)
                            if case .error(let e) = response {
                                cont.resume(throwing: ClientError.agentError(e))
                            } else {
                                cont.resume(returning: response)
                            }
                        } catch {
                            cont.resume(throwing: ClientError.decodeFailed(error))
                        }
                    }
                case .event:
                    do {
                        let event = try Framing.decodeEvent(envelope)
                        log.notice("yield event: \(String(describing: event), privacy: .public)")
                        eventContinuation?.yield(event)
                    } catch {
                        log.error("decode event failed: \(String(describing: error), privacy: .public)")
                    }
                default: break
                }
            } catch {
                log.error("decode error: \(String(describing: error), privacy: .public)")
            }
        }
        if !isComplete || data != nil {
            await receiveOne()
        }
    }
}
