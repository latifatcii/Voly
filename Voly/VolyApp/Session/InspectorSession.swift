import Foundation
import Network
import OSLog
import VolyProtocol
import VolyModels
import VolyHost

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "InspectorSession")

/// The top-level inspector session. Owns the connection, the state store, and
/// orchestrates the higher-level flows (connect → load hierarchy → select → edit).
@MainActor
@Observable
final class InspectorSession {
    let connections = ConnectionManager()
    let state = InspectorStateStore()
    let measurement = MeasurementPane()
    private var client: WebSocketClient?
    private var selectedPeer: ConnectionManager.Peer?
    var lastError: String?
    var lastMeasurementSummary: MeasurementSummary?

    /// Trailing-debounce handle for measurement updates. Fast mouse movement
    /// over the hierarchy would otherwise send a `.measure` command per frame.
    private var pendingMeasurementTask: Task<Void, Never>?
    /// When true, the first peer discovered over Bonjour is connected to
    /// automatically. Reset to false if the user explicitly disconnects.
    var autoConnectEnabled: Bool = true
    private var hasAutoConnected: Bool = false
    private let portFileWatcher = PortFileWatcher()
    private var fileDiscoveryTimer: Timer?

    init() {
        startFileDiscoveryLoop()
        connections.startBrowsing()
        connections.onPeerAppeared = { [weak self] peer in
            guard let self else { return }
            guard self.autoConnectEnabled, !self.hasAutoConnected else { return }
            guard self.state.connectionStatus == .disconnected else { return }
            self.hasAutoConnected = true
            log.notice("auto-connecting to first discovered peer: \(peer.displayName, privacy: .public)")
            Task { [weak self] in
                await self?.connect(to: peer)
            }
        }
    }

    func connect(to peer: ConnectionManager.Peer) async {
        selectedPeer = peer
        state.connectionStatus = .connecting
        lastError = nil
        let client = WebSocketClient()
        self.client = client
        do {
            try await client.connect(to: peer.endpoint)
            state.connectionStatus = .connected
            pumpEvents(client: client)
            await refreshHierarchy()
        } catch {
            state.connectionStatus = .disconnected
            lastError = error.localizedDescription
        }
    }

    func connectManually(host: String, port: UInt16) async {
        state.connectionStatus = .connecting
        lastError = nil
        let client = WebSocketClient()
        self.client = client
        let endpoint = Network.NWEndpoint.hostPort(
            host: Network.NWEndpoint.Host(host),
            port: Network.NWEndpoint.Port(rawValue: port)!
        )
        do {
            try await client.connect(to: endpoint)
            state.connectionStatus = .connected
            pumpEvents(client: client)
            await refreshHierarchy()
        } catch {
            state.connectionStatus = .disconnected
            lastError = error.localizedDescription
        }
    }

    func reconnect() async {
        guard let peer = selectedPeer else { return }
        await disconnect()
        await connect(to: peer)
    }

    func disconnect() async {
        await client?.disconnect()
        client = nil
        state.connectionStatus = .disconnected
        // Explicit disconnect disables auto-connect until next launch/toggle.
        autoConnectEnabled = false
        hasAutoConnected = false
    }

    private func startFileDiscoveryLoop() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.pollPortFiles()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fileDiscoveryTimer = timer
    }

    private func pollPortFiles() async {
        do {
            let devices = try await SimInventory().listDevices(bootedOnly: true)
            let agents = portFileWatcher.scan(deviceUDIDs: devices.map(\.udid))
            connections.updateFileDiscoveredPeers(agents)
        } catch {
            log.error("pollPortFiles: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - High-level operations

    func refreshHierarchy() async {
        guard let client else { return }
        do {
            let response = try await client.send(.getHierarchy)
            if case .hierarchy(let snapshot) = response {
                state.hierarchy = snapshot
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadSubtree(for id: ObjectID, depth: Int = 2) async {
        guard let client else { return }
        do {
            let response = try await client.send(.getSubtree(objectID: id, maxDepth: depth))
            if case .subtree(let node) = response {
                state.merge(subtree: node)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func select(_ id: ObjectID) async {
        log.notice("select(\(id)) called")
        // Make sure the hierarchy cache contains the target BEFORE we set
        // selectedViewID. Otherwise expansion/scroll run against a stale tree,
        // can't locate the node, and the middle panel stays collapsed.
        if state.findNode(id: id) == nil {
            log.info("select: node \(id) not in cached tree → refreshHierarchy")
            await refreshHierarchy()
        } else {
            log.info("select: node \(id) found in cached tree")
        }
        // Expand the ancestor chain first so the row is guaranteed to exist in
        // the rendered list by the time we set selectedViewID; the onChange
        // handler in HierarchyBrowser can then just scroll.
        state.expandAncestors(of: id)
        log.info("select: expandedNodeIDs=\(self.state.expandedNodeIDs)")
        state.selectedViewID = id
        // Mirror the selection onto the device overlay so the user sees the
        // same view highlighted in the simulator. Fire-and-forget — the
        // highlight is cosmetic and shouldn't block selection.
        _ = try? await client?.send(.highlight(objectID: id))
        await loadProperties(for: id)
        await loadConstraints(for: id)
    }

    func loadProperties(for id: ObjectID) async {
        guard let client else { return }
        do {
            let response = try await client.send(.getProperties(objectID: id))
            if case .properties(let bag) = response {
                state.propertyBag = bag
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadConstraints(for id: ObjectID) async {
        guard let client else { return }
        do {
            let response = try await client.send(.getConstraints(objectID: id))
            if case .constraints(let list) = response {
                state.constraints = list
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setProperty(_ request: SetPropertyRequest) async {
        guard let client else { return }
        do {
            let response = try await client.send(.setProperty(request))
            if case .subtree(let node) = response {
                state.merge(subtree: node)
                state.propertyBag.map { _ in }
                await loadProperties(for: request.objectID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setConstraint(_ request: SetConstraintRequest) async {
        guard let client else { return }
        do {
            _ = try await client.send(.setConstraint(request))
            await loadConstraints(for: request.anchorObjectID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func enterPickMode() async {
        _ = try? await client?.send(.enterPickMode)
        state.pickModeActive = true
    }

    func exitPickMode() async {
        _ = try? await client?.send(.exitPickMode)
        state.pickModeActive = false
        await clearSelection()
    }

    func clearSelection() async {
        state.selectedViewID = nil
        _ = try? await client?.send(.clearSelection)
    }

    func listUserDefaults(suite: String? = nil) async {
        guard let client else { return }
        do {
            let response = try await client.send(.userDefaultsList(suite: suite))
            if case .userDefaults(let items) = response {
                state.userDefaults = items
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setUserDefault(_ request: UserDefaultsSetRequest) async {
        _ = try? await client?.send(.userDefaultsSet(request))
        await listUserDefaults(suite: request.suite)
    }

    func deleteUserDefault(suite: String?, key: String) async {
        _ = try? await client?.send(.userDefaultsDelete(suite: suite, key: key))
        await listUserDefaults(suite: suite)
    }

    func openURL(_ url: URL) async -> (Bool, String?) {
        do {
            let response = try await client?.send(.openURL(url: url)) ?? .ack
            if case .urlResult(let success, let err) = response {
                return (success, err)
            }
        } catch {
            return (false, error.localizedDescription)
        }
        return (false, nil)
    }

    func applyPreview(_ config: PreviewConfig) async -> PreviewConfig.Applied? {
        do {
            if let response = try await client?.send(.setPreviewConfig(config)),
               case .previewApplied(let applied) = response {
                return applied
            }
        } catch {
            lastError = error.localizedDescription
        }
        return nil
    }

    func clearPreview() async {
        _ = try? await client?.send(.clearPreview)
    }

    /// Schedule a measurement-overlay update after a short debounce. Cancels
    /// any in-flight update. Pass `other == nil` to clear the overlay.
    func scheduleMeasurementUpdate(anchor: ObjectID?, other: ObjectID?) {
        pendingMeasurementTask?.cancel()
        pendingMeasurementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { return }
            await self?.performMeasurementUpdate(anchor: anchor, other: other)
        }
    }

    private func performMeasurementUpdate(anchor: ObjectID?, other: ObjectID?) async {
        guard let client else { return }

        // No anchor or no "other" → clear everything.
        guard let anchor, let other else {
            lastMeasurementSummary = nil
            _ = try? await client.send(.clearMeasure)
            return
        }

        guard let anchorNode = state.findNode(id: anchor),
              let otherNode  = state.findNode(id: other) else {
            lastMeasurementSummary = nil
            _ = try? await client.send(.clearMeasure)
            return
        }

        let sharedWindow = state.containingWindowID(of: anchor)
            == state.containingWindowID(of: other)

        guard let overlay = FrameMeasurement.compute(
            anchor: anchorNode, other: otherNode, sharedWindow: sharedWindow)
        else {
            lastMeasurementSummary = sharedWindow
                ? nil  // NaN / zero-size / other degenerate — hide the badge
                : MeasurementSummary(kind: .crossWindow, horizontal: nil, vertical: nil)
            _ = try? await client.send(.clearMeasure)
            return
        }

        // sameView → header shows "same view", no on-simulator guides needed.
        if overlay.summary.kind == .sameView {
            lastMeasurementSummary = overlay.summary
            _ = try? await client.send(.clearMeasure)
            return
        }

        lastMeasurementSummary = overlay.summary
        _ = try? await client.send(.measure(overlay: overlay))
    }

    func resolveSource(for id: ObjectID) async -> SourceInfo? {
        do {
            if let response = try await client?.send(.resolveSource(objectID: id)),
               case .sourceInfo(let info) = response {
                return info
            }
        } catch {
            lastError = error.localizedDescription
        }
        return nil
    }

    // MARK: - Events

    private func pumpEvents(client: WebSocketClient) {
        Task { @MainActor [weak self] in
            log.info("pumpEvents: started")
            for await event in client.events {
                log.notice("event received: \(String(describing: event), privacy: .public)")
                guard let self else { return }
                switch event {
                case .selectionChanged(let id):
                    await self.select(id)
                case .hierarchyChanged:
                    await self.refreshHierarchy()
                case .viewInvalidated(let id):
                    await self.loadSubtree(for: id)
                case .connectionWarning(let message):
                    self.lastError = message
                case .hoverTarget:
                    break   // TODO Task 9: route to measurement.hoverID
                case .measureClick(let id):
                    await self.select(id)
                }
            }
            log.info("pumpEvents: stream ended")
            // The client's event stream ends when the connection closes. Reset
            // state so the watcher's next scan can auto-connect to a new peer
            // (e.g. after the injected app was relaunched with a new pid).
            guard let self else { return }
            self.state.connectionStatus = .disconnected
            self.hasAutoConnected = false
            self.lastError = nil
            self.client = nil
            // A new peer may have already been announced while we were still
            // connected (race: new app's port file appears before the old
            // connection's TCP reset arrives). In that case onPeerAppeared
            // won't re-fire, so reach into the current peer list and pick up
            // whatever's there.
            if self.autoConnectEnabled, let peer = self.connections.peers.first {
                self.hasAutoConnected = true
                log.notice("pumpEvents: reconnecting to known peer \(peer.displayName, privacy: .public)")
                Task { [weak self] in
                    await self?.connect(to: peer)
                }
            }
        }
    }
}
