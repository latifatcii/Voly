import CoreGraphics
import Foundation
import Network
import OSLog
import VolyCodables
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
    let hoverMonitor = SimulatorHoverMonitor()
    /// The connection the inspector UI is driving.
    private var client: WebSocketClient?
    /// Every live agent connection, keyed by peer id. Several apps can stay
    /// connected at once; `client` is the one commands currently go to, and
    /// each client is bound to the single process its handshake verified.
    private var clients: [ConnectionManager.Peer.ID: WebSocketClient] = [:]
    private static let maxPooledConnections = 8
    /// Peers with a background connection attempt in flight.
    private var connectingPeerIDs: Set<ConnectionManager.Peer.ID> = []
    private var pendingPickTransition: Task<Void, Never>?
    private var selectedPeer: ConnectionManager.Peer?
    /// Booted simulators and their per-simulator runtime integration.
    let simulators = VolySimulatorManager()
    /// Android emulators and the agents attached to the apps running in them.
    let android = AndroidDeviceManager()
    let sourceNavigator = VolySourceNavigator()
    let screenshots = VolyScreenshotManager()
    /// AI agents' way in (MCP). Started by the app delegate.
    let agentAccess = MCPService()
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

    /// - Parameter startDiscovery: false builds a session that never looks
    ///   for or connects to agents — used to render the UI from fixtures.
    init(startDiscovery: Bool = true) {
        hoverMonitor.session = self
        guard startDiscovery else { return }
        startFileDiscoveryLoop()
        connections.startBrowsing()
        android.policyProvider = { [weak self] in self?.simulators.policy ?? InjectionPolicy() }
        android.onAgentsChanged = { [weak self] agents in
            self?.connections.updateAndroidPeers(agents)
        }
        connections.onPeerAppeared = { [weak self] peer in
            guard let self, self.autoConnectEnabled else { return }
            if !self.hasAutoConnected, self.state.connectionStatus == .disconnected {
                self.hasAutoConnected = true
                log.notice("auto-connecting to first discovered peer: \(peer.displayName, privacy: .public)")
                Task { [weak self] in
                    await self?.connect(to: peer)
                }
            } else if peer.deviceUDID != nil || peer.androidSerial != nil {
                // Every other instrumented simulator app is connected in the
                // background, so picking a view in any of them can bring it
                // into the inspector without a click here first.
                Task { [weak self] in
                    await self?.connectInBackground(peer)
                }
            }
        }
    }

    func connect(to peer: ConnectionManager.Peer) async {
        lastError = nil
        if state.activePeerID == peer.id, client != nil { return }
        await leaveActiveAgent()
        selectedPeer = peer

        // An agent serves one connection and drops it when another arrives,
        // so a second attempt would cut off the first. If one is already on
        // its way for this app (a background connect, an AI agent's
        // request), use what it brings.
        for _ in 0..<50 where clients[peer.id] == nil && connectingPeerIDs.contains(peer.id) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let pooled = clients[peer.id] {
            await activate(pooled, peerID: peer.id)
            return
        }
        state.connectionStatus = .connecting
        connectingPeerIDs.insert(peer.id)
        defer { connectingPeerIDs.remove(peer.id) }
        let client = WebSocketClient()
        do {
            try await client.connect(to: peer.endpoint, authToken: peer.token, expectedPID: peer.pid)
            await adopt(client, peerID: peer.id)
            log.notice("connected to \(peer.displayName, privacy: .public) pid=\(peer.pid ?? -1) sim=\(peer.deviceUDID ?? "-", privacy: .public)")
        } catch {
            state.connectionStatus = .disconnected
            lastError = error.localizedDescription
            log.error("connect to \(peer.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func connectManually(host: String, port: UInt16) async {
        lastError = nil
        await leaveActiveAgent()
        state.connectionStatus = .connecting
        let client = WebSocketClient()
        let endpoint = Network.NWEndpoint.hostPort(
            host: Network.NWEndpoint.Host(host),
            port: Network.NWEndpoint.Port(rawValue: port)!
        )
        do {
            try await client.connect(to: endpoint)
            await adopt(client, peerID: "manual:\(host):\(port)")
        } catch {
            state.connectionStatus = .disconnected
            lastError = error.localizedDescription
        }
    }

    /// Add a freshly handshaken client to the pool and make it active.
    private func adopt(_ client: WebSocketClient, peerID: String) async {
        await pool(client, peerID: peerID)
        await activate(client, peerID: peerID)
    }

    private func pool(_ client: WebSocketClient, peerID: String) async {
        if clients.count >= Self.maxPooledConnections,
           let evicted = clients.keys.first(where: { $0 != state.activePeerID }) {
            await clients.removeValue(forKey: evicted)?.disconnect()
        }
        clients[peerID] = client
        state.connectedPeerIDs = Set(clients.keys)
        pumpEvents(client: client, peerID: peerID)
        // Pick mode covers every connected app, including late arrivals.
        if state.pickModeActive { _ = try? await client.send(.enterPickMode) }
    }

    /// Connect without taking over the inspector. The app becomes active
    /// when the user picks a view in it or clicks it in the list.
    private func connectInBackground(_ peer: ConnectionManager.Peer) async {
        guard clients[peer.id] == nil, connectingPeerIDs.insert(peer.id).inserted else { return }
        defer { connectingPeerIDs.remove(peer.id) }
        let client = WebSocketClient()
        do {
            try await client.connect(to: peer.endpoint, authToken: peer.token, expectedPID: peer.pid)
        } catch {
            log.info("background connect to \(peer.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard clients[peer.id] == nil else {
            await client.disconnect()
            return
        }
        log.notice("connected in background to \(peer.displayName, privacy: .public) pid=\(peer.pid ?? -1) sim=\(peer.deviceUDID ?? "-", privacy: .public)")
        if self.client == nil, state.connectionStatus == .disconnected {
            // Nothing is being inspected (the first connection failed or its
            // app went away): this one takes the inspector.
            selectedPeer = peer
            hasAutoConnected = true
            await adopt(client, peerID: peer.id)
        } else {
            await pool(client, peerID: peer.id)
        }
    }

    private func activate(_ client: WebSocketClient, peerID: String) async {
        self.client = client
        // Pick mode is a property of the inspector, not of one app: it
        // survives moving between apps.
        let picking = state.pickModeActive
        state.resetForNewAgent()
        state.pickModeActive = picking
        measurement.reset()
        lastMeasurementSummary = nil
        state.agent = await client.agent
        state.activePeerID = peerID
        state.connectedPeerIDs = Set(clients.keys)
        state.connectionStatus = .connected
        await refreshHierarchy()
        guard client === self.client else { return }   // switched again meanwhile
        await refreshRuntimeState()
    }

    /// Before switching apps: take Voly's selection highlight and
    /// measurement guides off the app we stop driving. Its connection stays
    /// in the pool, and it stays pickable if pick mode is on.
    private func leaveActiveAgent() async {
        guard let client else { return }
        self.client = nil
        state.activePeerID = nil
        _ = try? await client.send(.clearMeasure)
        _ = try? await client.send(.clearSelection)
    }

    /// The user picked a view in an app the inspector wasn't showing.
    private func switchActive(to client: WebSocketClient, peerID: String) async {
        guard client !== self.client, clients[peerID] === client else { return }
        await leaveActiveAgent()
        selectedPeer = connections.peers.first { $0.id == peerID } ?? selectedPeer
        log.notice("pick in \(self.selectedPeer?.displayName ?? peerID, privacy: .public) — switching the inspector to it")
        await activate(client, peerID: peerID)
    }

    func reconnect() async {
        guard let peer = selectedPeer else { return }
        await disconnect()
        await connect(to: peer)
    }

    func disconnect() async {
        hoverMonitor.stop()
        for pooled in clients.values { await pooled.disconnect() }
        clients.removeAll()
        client = nil
        state.connectionStatus = .disconnected
        state.resetForNewAgent()
        state.activePeerID = nil
        state.connectedPeerIDs = []
        measurement.reset()
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
            var devices = try await SimInventory().listDevices(bootedOnly: true)
            #if DEBUG
            if let only = ScriptedRun.simulators { devices = devices.filter { only.contains($0.udid) } }
            #endif
            let agents = portFileWatcher.scan(deviceUDIDs: devices.map(\.udid))
            connections.updateFileDiscoveredPeers(agents)
            // The user navigates in the simulator too; keep the Dismiss/Pop
            // buttons honest without hooking anything in the app.
            if client != nil { await refreshNavigationState() }
        } catch {
            log.error("pollPortFiles: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - High-level operations

    func refreshHierarchy() async {
        guard let client else { return }
        do {
            let response = try await client.send(.getHierarchy)
            if case .hierarchy(let snapshot) = response, client === self.client {
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
            if case .subtree(let node) = response, client === self.client {
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
        if state.selectedViewID != id { state.sourceLookup = .idle }
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
            if case .properties(let bag) = response, client === self.client {
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
            if case .constraints(let list) = response, client === self.client {
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

    /// Enter Pick mode: the agent puts up the greedy blue overlay on the sim,
    /// and the Mac-side hover monitor starts driving live measurements against
    /// whatever view is selected. If Accessibility isn't granted, the hover
    /// monitor fails silently — clicking still works, just no hover measure.
    ///
    /// Pick mode is switched on in *every* connected app, not just the one
    /// being inspected: clicking a view in any simulator selects it, and if
    /// it belongs to another app the inspector switches to that app.
    ///
    /// - Parameter announceMissingAccessibility: false when pick mode comes
    ///   on by itself (showing the inspector), so that never nags.
    func enterPickMode(announceMissingAccessibility: Bool = true) async {
        await pickTransition { [self] in
            guard !state.pickModeActive else { return }
            _ = hoverMonitor.start(announceIfUntrusted: announceMissingAccessibility)
            state.pickModeActive = true
            for pooled in clients.values {
                _ = try? await pooled.send(.enterPickMode)
            }
        }
    }

    func exitPickMode() async {
        await pickTransition { [self] in
            guard state.pickModeActive else { return }
            hoverMonitor.stop()
            state.pickModeActive = false
            for pooled in clients.values {
                _ = try? await pooled.send(.exitPickMode)
                _ = try? await pooled.send(.clearMeasure)
            }
            measurement.reset()
            lastMeasurementSummary = nil
            await clearSelection()
        }
    }

    /// Entering and leaving pick mode each talk to every connected app. Run
    /// them strictly one after another, so a quick hide-then-show can't
    /// leave some apps in pick mode and others out of it.
    private func pickTransition(_ body: @escaping @MainActor () async -> Void) async {
        let previous = pendingPickTransition
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        pendingPickTransition = task
        await task.value
    }

    /// Live hit-test + measurement + draw on the agent, in one round-trip.
    /// The agent resolves anchor + cursor-hit views, computes the overlay
    /// using fresh window-coord frames, draws it, and returns the summary
    /// for the header badge + the hovered view's id for the UI hoverID state.
    ///
    /// Chosen over a client-side approach because snapshot `windowFrame`
    /// data can be stale, and views like iOS 26's floating-bar passthrough
    /// container override `point(inside:with:)` in ways the snapshot can't
    /// represent.
    func liveMeasureHover(
        anchor: ObjectID,
        x: Double,
        y: Double,
        sceneID: ObjectID
    ) async -> (otherID: ObjectID?, summary: MeasurementSummary?) {
        guard let client else { return (nil, nil) }
        do {
            let response = try await client.send(.measureHover(
                anchorID: anchor, x: x, y: y, sceneID: sceneID))
            if case .measureHoverResult(let otherID, let summary) = response {
                return (otherID, summary)
            }
        } catch {
            // Silently drop — hover errors are cosmetic; next move will retry.
        }
        return (nil, nil)
    }

    func clearSelection() async {
        state.selectedViewID = nil
        state.sourceLookup = .idle
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

    /// Schedule a measurement-overlay update after a short debounce. Cancels
    /// any in-flight update. Pass `other == nil` to clear the overlay.
    ///
    /// No-op when `pickModeActive` — the simulator-hover path
    /// (`liveMeasureHover`) already does hit-test + compute + draw on the
    /// agent with live frames, so double-running this would redraw using
    /// stale snapshot frames.
    func scheduleMeasurementUpdate(anchor: ObjectID?, other: ObjectID?) {
        if state.pickModeActive { return }
        pendingMeasurementTask?.cancel()
        pendingMeasurementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { return }
            await self?.performMeasurementUpdate(anchor: anchor, other: other)
        }
    }

    private func performMeasurementUpdate(anchor: ObjectID?, other: ObjectID?) async {
        guard let client else {
            log.info("performMeasurementUpdate: no client")
            return
        }

        // No anchor or no "other" → clear everything.
        guard let anchor, let other else {
            log.info("performMeasurementUpdate: anchor=\(anchor.map(String.init) ?? "nil") other=\(other.map(String.init) ?? "nil") → clearMeasure")
            lastMeasurementSummary = nil
            _ = try? await client.send(.clearMeasure)
            return
        }

        guard let anchorNode = state.findNode(id: anchor),
              let otherNode  = state.findNode(id: other) else {
            log.info("performMeasurementUpdate: findNode failed (anchor=\(anchor) other=\(other)) — snapshot stale?")
            lastMeasurementSummary = nil
            _ = try? await client.send(.clearMeasure)
            return
        }

        let sharedWindow = state.containingWindowID(of: anchor)
            == state.containingWindowID(of: other)

        guard let overlay = FrameMeasurement.compute(
            anchor: anchorNode, other: otherNode, sharedWindow: sharedWindow)
        else {
            log.info("performMeasurementUpdate: FrameMeasurement.compute returned nil (anchor=\(anchor) other=\(other) sharedWindow=\(sharedWindow))")
            lastMeasurementSummary = sharedWindow
                ? nil  // NaN / zero-size / other degenerate — hide the badge
                : MeasurementSummary(kind: .crossWindow, horizontal: nil, vertical: nil)
            _ = try? await client.send(.clearMeasure)
            return
        }
        let aFrame = (anchorNode.windowFrame ?? anchorNode.frame).cg
        let oFrame = (otherNode.windowFrame ?? otherNode.frame).cg
        log.notice("performMeasurementUpdate: anchor=\(anchor)(\(anchorNode.className, privacy: .public) wf=\(Int(aFrame.minX)),\(Int(aFrame.minY)),\(Int(aFrame.width))x\(Int(aFrame.height))) other=\(other)(\(otherNode.className, privacy: .public) wf=\(Int(oFrame.minX)),\(Int(oFrame.minY)),\(Int(oFrame.width))x\(Int(oFrame.height))) kind=\(String(describing: overlay.summary.kind), privacy: .public) → sending .measure")

        // sameView → header shows "same view", no on-simulator guides needed.
        if overlay.summary.kind == .sameView {
            lastMeasurementSummary = overlay.summary
            _ = try? await client.send(.clearMeasure)
            return
        }

        lastMeasurementSummary = overlay.summary
        _ = try? await client.send(.measure(overlay: overlay))
    }

    // MARK: - Runtime features

    /// Simulator the active agent runs in, if it is a simulator app.
    var activeSimulatorUDID: String? {
        state.agent?.simulatorUDID ?? selectedPeer?.deviceUDID
    }

    /// The inspector is driving an Android app.
    var isActiveAgentAndroid: Bool {
        state.agent?.isAndroid ?? (client != nil && selectedPeer?.androidSerial != nil)
    }

    /// adb serial of the emulator or device the active Android app runs on.
    var activeAndroidSerial: String? {
        guard client != nil, isActiveAgentAndroid else { return nil }
        return selectedPeer?.androidSerial
            ?? state.activePeerID.flatMap { id in connections.peers.first { $0.id == id }?.androidSerial }
    }

    /// Localization + navigation state for the newly active agent.
    private func refreshRuntimeState() async {
        await refreshLocalizationState()
        await refreshNavigationState()
    }

    func refreshLocalizationState() async {
        guard let client else { return }
        if case .localization(let localization)? = try? await client.send(.localizationState),
           client === self.client {
            state.localization = localization
        }
    }

    /// `language == nil` restores the app's own language behaviour.
    func setLocalization(language: String?, layoutDirection: LayoutDirectionMode) async {
        guard let client else { return }
        let request = LocalizationOverrideRequest(
            language: language, layoutDirectionMode: layoutDirection, refreshUI: true
        )
        do {
            let response = try await client.send(.setLocalizationOverride(request))
            guard case .localization(let localization) = response, client === self.client else { return }
            state.localization = localization
            state.actionStatus = ActionStatus(message: Self.describe(localization), isError: false)
            log.notice("localization override: \(language ?? "system", privacy: .public)")
            await refreshHierarchy()
        } catch {
            state.actionStatus = ActionStatus(message: error.localizedDescription, isError: true)
        }
    }

    func refreshLocalizedUI() async {
        guard let client else { return }
        do {
            let response = try await client.send(.refreshLocalizedUI)
            guard case .localization(let localization) = response, client === self.client else { return }
            state.localization = localization
            state.actionStatus = ActionStatus(message: Self.describe(localization), isError: false)
            await refreshHierarchy()
        } catch {
            state.actionStatus = ActionStatus(message: error.localizedDescription, isError: true)
        }
    }

    private static func describe(_ localization: LocalizationState) -> String {
        let language = localization.activeOverride.map { code in
            localization.available.first { $0.code == code }?.displayName ?? code
        } ?? "System language"
        guard let refresh = localization.lastRefresh else { return language }
        var parts = ["\(language): \(refresh.updated) updated"]
        if refresh.unresolved > 0 { parts.append("\(refresh.unresolved) not refreshable in place") }
        if refresh.ambiguous > 0 { parts.append("\(refresh.ambiguous) ambiguous") }
        return parts.joined(separator: ", ")
    }

    func refreshNavigationState() async {
        guard let client else { return }
        if case .navigationState(let navigation)? = try? await client.send(.navigationState),
           client === self.client, state.navigation != navigation {
            state.navigation = navigation
        }
    }

    func navigate(_ action: NavigationAction) async {
        guard let client else { return }
        do {
            let response = try await client.send(.navigate(action))
            guard case .navigationResult(let result) = response, client === self.client else { return }
            state.navigation = result.state
            log.notice("navigate \(action.rawValue, privacy: .public): performed=\(result.performed) \(result.message ?? "", privacy: .public)")
            if result.performed {
                state.actionStatus = nil
                // Let the transition settle, then show the new screen.
                try? await Task.sleep(for: .milliseconds(650))
                guard client === self.client else { return }
                await refreshNavigationState()
                await refreshHierarchy()
            } else {
                state.actionStatus = ActionStatus(message: result.message ?? "Not available.", isError: true)
            }
        } catch {
            state.actionStatus = ActionStatus(message: error.localizedDescription, isError: true)
        }
    }

    /// Resolve the selection to source and open the best answer in Xcode.
    /// When the same class maps to several files the choice is left to the
    /// user, in the header.
    func jumpToSource() async {
        guard let client, let id = state.selectedViewID else { return }
        if case .resolved(id, let lookup) = state.sourceLookup, let best = lookup.locations.first,
           !lookup.isAmbiguous {
            await openSource(best)
            return
        }
        state.sourceLookup = .resolving(id)
        do {
            let response = try await client.send(.resolveSource(objectID: id))
            guard case .sourceInfo(let info) = response else { throw WebSocketClient.ClientError.unexpectedResponse }
            let lookup = await sourceNavigator.resolve(info)
            guard state.selectedViewID == id, client === self.client else { return }
            state.sourceLookup = .resolved(id, lookup)
            log.notice("source lookup for \(info.className, privacy: .public): \(lookup.locations.count) location(s)")
            if let best = lookup.locations.first, !lookup.isAmbiguous { await openSource(best) }
        } catch {
            guard state.selectedViewID == id else { return }
            state.sourceLookup = .resolved(id, SourceLookup(locations: [], note: error.localizedDescription))
        }
    }

    func openSource(_ location: SourceLocation) async {
        do {
            try await sourceNavigator.open(location)
        } catch {
            state.actionStatus = ActionStatus(message: error.localizedDescription, isError: true)
        }
    }

    func captureScreenshot(_ mode: VolyScreenshotManager.Mode, to destination: VolyScreenshotManager.Destination) async {
        let appName = state.agent?.processName ?? selectedPeer?.displayName
        do {
            let image: VolyScreenshotManager.Capture
            switch mode {
            case .fullSimulator where activeAndroidSerial != nil:
                // The emulator's display through adb; it comes as shown, already upright.
                guard let serial = activeAndroidSerial else { throw VolyScreenshotManager.CaptureError.noSimulator }
                let png = try await android.screenshot(serial: serial)
                let size = PNGSize.read(png)
                image = .init(png: png, pixelWidth: size?.width ?? 0, pixelHeight: size?.height ?? 0)
            case .fullSimulator:
                guard let udid = await resolveScreenshotSimulator() else {
                    throw VolyScreenshotManager.CaptureError.noSimulator
                }
                // The framebuffer is always device-upright; ask the app which
                // way its interface is turned so the saved image matches.
                var orientation = InterfaceOrientation.unknown
                if let client, activeSimulatorUDID == udid,
                   case .screenInfo(let info)? = try? await client.send(.screenInfo) {
                    orientation = info.orientation
                }
                image = try await screenshots.captureSimulator(udid: udid, orientation: orientation)
            case .application:
                guard let client else { throw WebSocketClient.ClientError.notConnected }
                guard case .screenshot(let shot) = try await client.send(.captureScreenshot(.application)) else {
                    throw WebSocketClient.ClientError.unexpectedResponse
                }
                image = .init(png: shot.png, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight)
            case .selectedView:
                guard let client else { throw WebSocketClient.ClientError.notConnected }
                guard let id = state.selectedViewID else { throw VolyScreenshotManager.CaptureError.noSelection }
                guard case .screenshot(let shot) = try await client.send(.captureScreenshot(.view(id))) else {
                    throw WebSocketClient.ClientError.unexpectedResponse
                }
                image = .init(png: shot.png, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight)
            }
            let subject = mode == .selectedView
                ? state.selectedViewID.flatMap { state.findNode(id: $0)?.className }
                : nil
            let message = try screenshots.deliver(image, mode: mode, appName: appName, subject: subject, to: destination)
            state.actionStatus = ActionStatus(message: message, isError: false)
            log.notice("screenshot \(String(describing: mode), privacy: .public): \(image.pixelWidth)x\(image.pixelHeight)")
        } catch {
            state.actionStatus = ActionStatus(message: error.localizedDescription, isError: true)
            log.error("screenshot \(String(describing: mode), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveScreenshotSimulator() async -> String? {
        if let udid = activeSimulatorUDID { return udid }
        return try? await SimInventory().listDevices(bootedOnly: true).first?.udid
    }

    // MARK: - AI agent access

    /// Look for agents now rather than at the next poll.
    func refreshDiscovery() async {
        await pollPortFiles()
    }

    /// Send a command to any discovered app, connecting to it first if
    /// needed. Unlike the inspector's own operations this doesn't change
    /// which app the window is showing.
    func send(_ command: Command, toPeer peerID: String) async throws -> Response {
        if clients[peerID] == nil, let peer = connections.peers.first(where: { $0.id == peerID }) {
            await connectInBackground(peer)
            // Another attempt was already under way: give it a moment.
            for _ in 0..<30 where clients[peerID] == nil && connectingPeerIDs.contains(peerID) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let client = clients[peerID] else { throw WebSocketClient.ClientError.notConnected }
        return try await client.send(command)
    }

    /// Something other than the inspector changed the app: show its
    /// current state if it is the one on screen.
    func reloadAfterExternalChange(peerID: String) async {
        guard peerID == state.activePeerID else { return }
        await refreshHierarchy()
        if let id = state.selectedViewID {
            await loadProperties(for: id)
            await loadConstraints(for: id)
        }
        await refreshRuntimeState()
    }

    /// Select a view on someone else's behalf, switching the inspector to
    /// its app first.
    func select(_ id: ObjectID, inPeer peerID: String) async throws {
        if state.activePeerID != peerID {
            guard let peer = connections.peers.first(where: { $0.id == peerID }) else {
                throw WebSocketClient.ClientError.notConnected
            }
            await connect(to: peer)
            guard state.activePeerID == peerID else { throw WebSocketClient.ClientError.notConnected }
        }
        await select(id)
    }

    // MARK: - Events

    private func pumpEvents(client: WebSocketClient, peerID: String) {
        Task { @MainActor [weak self] in
            log.info("pumpEvents: started for \(peerID, privacy: .public)")
            for await event in client.events {
                guard let self else { return }
                if client !== self.client {
                    // A background app only speaks up for one thing: the user
                    // picked a view in it. That means "inspect this app now".
                    guard case .selectionChanged(let id) = event else { continue }
                    await self.switchActive(to: client, peerID: peerID)
                    if client === self.client { await self.select(id) }
                    continue
                }
                log.notice("event received: \(String(describing: event), privacy: .public)")
                switch event {
                case .selectionChanged(let id):
                    if self.state.selectedViewID == id {
                        await self.clearSelection()
                    } else {
                        await self.select(id)
                    }
                case .hierarchyChanged:
                    await self.refreshHierarchy()
                case .viewInvalidated(let id):
                    await self.loadSubtree(for: id)
                case .connectionWarning(let message):
                    self.lastError = message
                case .hoverTarget(let id):
                    self.measurement.hoverID = id
                }
            }
            log.info("pumpEvents: stream ended for \(peerID, privacy: .public)")
            // The stream ends when the connection closes (app terminated,
            // relaunched, or simulator shut down).
            guard let self else { return }
            if self.clients[peerID] === client { self.clients[peerID] = nil }
            self.state.connectedPeerIDs = Set(self.clients.keys)
            guard client === self.client else { return }
            self.hoverMonitor.stop()
            self.client = nil
            self.state.connectionStatus = .disconnected
            self.state.resetForNewAgent()
            self.state.activePeerID = nil
            self.hasAutoConnected = false
            self.lastError = nil
            // A new peer may have already been announced while we were still
            // connected (race: new app's port file appears before the old
            // connection's TCP reset arrives). In that case onPeerAppeared
            // won't re-fire, so reach into the current peer list and pick up
            // whatever's there — preferring a relaunch of the same app.
            if self.autoConnectEnabled {
                let previous = self.selectedPeer
                let peers = self.connections.peers.filter { $0.id != peerID }
                let next = peers.first {
                    $0.bundleIdentifier != nil && $0.bundleIdentifier == previous?.bundleIdentifier
                        && $0.deviceUDID == previous?.deviceUDID
                } ?? peers.first
                if let next {
                    self.hasAutoConnected = true
                    log.notice("pumpEvents: reconnecting to known peer \(next.displayName, privacy: .public)")
                    Task { [weak self] in
                        await self?.connect(to: next)
                    }
                }
            }
        }
    }
}
