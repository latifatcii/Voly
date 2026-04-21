import Foundation
import Network
import OSLog
import VolyProtocol

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "ConnectionManager")

/// Discovers VolyAgent-advertised services over Bonjour and maintains the list of
/// known peers. Uses `NWBrowser` so we don't need the legacy NetServiceBrowser.
@MainActor
@Observable
final class ConnectionManager {
    struct Peer: Identifiable, Hashable {
        let id: String              // service name is unique within the Bonjour domain
        let displayName: String
        let endpoint: NWEndpoint
    }

    private(set) var peers: [Peer] = []
    private(set) var isBrowsing = false
    private(set) var lastError: String?

    /// Fires once per newly-discovered peer. InspectorSession uses this to
    /// auto-connect to the first peer that shows up.
    var onPeerAppeared: ((Peer) -> Void)?

    private var announcedPeers: Set<String> = []
    private var browser: NWBrowser?

    func startBrowsing() {
        guard !isBrowsing else { return }
        log.info("startBrowsing for \(ProtocolVersion.bonjourServiceType, privacy: .public)")
        let descriptor = NWBrowser.Descriptor.bonjour(type: ProtocolVersion.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        isBrowsing = true

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            log.info("browse results changed: \(results.count, privacy: .public)")
            for r in results {
                log.info("  endpoint=\(String(describing: r.endpoint), privacy: .public)")
            }
            var seen = Set<String>()
            let mapped: [Peer] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                if !seen.insert(name).inserted { return nil }
                return Peer(id: name, displayName: name, endpoint: result.endpoint)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peers = mapped
                // Notify observers about genuinely new peers, exactly once each.
                for peer in mapped where !self.announcedPeers.contains(peer.id) {
                    self.announcedPeers.insert(peer.id)
                    self.onPeerAppeared?(peer)
                }
                // Forget peers that disappeared so they can be re-announced if they come back.
                self.announcedPeers = self.announcedPeers.intersection(mapped.map(\.id))
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            log.info("browser state: \(String(describing: state), privacy: .public)")
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

}
