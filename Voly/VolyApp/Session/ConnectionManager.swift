import Foundation
import Network
import OSLog
import VolyProtocol
import VolyHost

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "ConnectionManager")

/// Discovers VolyAgent peers via both Bonjour (SDK-integrated apps) and
/// simulator port files (injected apps), and presents one unified list.
@MainActor
@Observable
final class ConnectionManager {
    enum Source: Hashable {
        case bonjour
        case portFile(deviceUDID: String)
    }

    struct Peer: Identifiable, Hashable {
        let id: String
        let displayName: String
        let endpoint: NWEndpoint
        let source: Source
    }

    private(set) var peers: [Peer] = []
    private(set) var isBrowsing = false
    private(set) var lastError: String?

    /// Fires once per newly-discovered peer across any source.
    var onPeerAppeared: ((Peer) -> Void)?

    private var announcedPeers: Set<String> = []
    private var browser: NWBrowser?

    private var bonjourPeers: [Peer] = []
    private var filePeers: [Peer] = []

    // MARK: - Bonjour

    func startBrowsing() {
        guard !isBrowsing else { return }
        log.info("startBrowsing for \(ProtocolVersion.bonjourServiceType, privacy: .public)")
        let descriptor = NWBrowser.Descriptor.bonjour(type: ProtocolVersion.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        isBrowsing = true

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var seen = Set<String>()
            let mapped: [Peer] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                if !seen.insert(name).inserted { return nil }
                return Peer(id: "bonjour:\(name)", displayName: name,
                            endpoint: result.endpoint, source: .bonjour)
            }
            Task { @MainActor [weak self] in
                self?.bonjourPeers = mapped
                self?.recomputeAndAnnounce()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case let .failed(error) = state {
                Task { @MainActor [weak self] in
                    self?.lastError = error.localizedDescription
                    self?.isBrowsing = false
                }
            }
        }
        browser.start(queue: .main)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    // MARK: - File-discovered agents

    /// Replace the file-discovered peer set with the latest scan. Called from a timer.
    func updateFileDiscoveredPeers(_ agents: [DiscoveredAgent]) {
        filePeers = agents.map { agent in
            let port = NWEndpoint.Port(rawValue: agent.port) ?? .any
            return Peer(
                id: "file:\(agent.deviceUDID):\(agent.bundleIdentifier)",
                displayName: "\(agent.processName) (injected)",
                endpoint: .hostPort(host: .ipv4(.loopback), port: port),
                source: .portFile(deviceUDID: agent.deviceUDID)
            )
        }
        recomputeAndAnnounce()
    }

    // MARK: - Merge

    private func recomputeAndAnnounce() {
        let merged = bonjourPeers + filePeers
        self.peers = merged

        for peer in merged where !announcedPeers.contains(peer.id) {
            announcedPeers.insert(peer.id)
            onPeerAppeared?(peer)
        }
        announcedPeers = announcedPeers.intersection(merged.map(\.id))
    }
}
