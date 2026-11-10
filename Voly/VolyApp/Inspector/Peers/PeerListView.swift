import SwiftUI
import VolyHost

/// Top of the Tree tab: booted simulators with their runtime-integration
/// switch and running apps, any other discovered agents, and manual connect.
struct PeerListView: View {
    @Bindable var session: InspectorSession
    @State private var manualHost: String = "127.0.0.1"
    @State private var manualPort: String = ""
    @State private var showManual: Bool = false
    @State private var relaunchCandidate: RelaunchCandidate?

    private struct RelaunchCandidate: Identifiable {
        let udid: String
        let simulatorName: String
        let bundleIdentifier: String
        var id: String { "\(udid):\(bundleIdentifier)" }
    }

    private var simulators: VolySimulatorManager { session.simulators }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle("Simulators")
                Spacer()
                Toggle("All simulators", isOn: Binding(
                    get: { simulators.preference.allSimulators },
                    set: { all in Task { await simulators.setIntegratesAllSimulators(all) } }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .padding(.trailing, 8)
                .padding(.top, 8)
                .help("Integrate with every booted simulator automatically. Switch a simulator off below to leave it alone, or uncheck this to pick simulators by hand.")
            }
            if let error = simulators.stagingError {
                caption(error, color: .red)
            }
            if let error = simulators.discoveryError {
                caption(error, color: .orange)
            } else if simulators.simulators.isEmpty {
                caption("No booted simulators.", color: .secondary)
            }
            ForEach(simulators.simulators) { simulator in
                simulatorSection(simulator)
            }

            let others = otherPeers
            if !others.isEmpty {
                sectionTitle("Other Agents")
                ForEach(others) { peer in
                    peerRow(peer, subtitle: nil)
                }
            }

            Divider().padding(.vertical, 4)

            DisclosureGroup(isExpanded: $showManual) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("host", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("port", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                    Button("Connect") {
                        if let p = UInt16(manualPort) {
                            Task { await session.connectManually(host: manualHost, port: p) }
                        }
                    }
                    .disabled(UInt16(manualPort) == nil || manualHost.isEmpty)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            } label: {
                Text("Manual connect").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
        .confirmationDialog(
            "Relaunch \(relaunchCandidate?.bundleIdentifier ?? "") with Voly?",
            isPresented: Binding(get: { relaunchCandidate != nil }, set: { if !$0 { relaunchCandidate = nil } }),
            presenting: relaunchCandidate
        ) { candidate in
            Button("Relaunch") {
                Task {
                    do {
                        try await simulators.relaunch(bundleIdentifier: candidate.bundleIdentifier, on: candidate.udid)
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text("The app on \(candidate.simulatorName) is terminated and launched again with the Voly agent. Its current state is lost and an attached Xcode debug session ends.")
        }
    }

    // MARK: - Simulator

    @ViewBuilder
    private func simulatorSection(_ simulator: VolySimulatorManager.Simulator) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
            VStack(alignment: .leading, spacing: 0) {
                Text(simulator.device.name).lineLimit(1)
                Text(simulator.runtimeName).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if simulator.isBusy {
                ProgressView().controlSize(.small)
            }
            Toggle("Runtime integration", isOn: Binding(
                get: { simulator.integration.isActive },
                set: { enabled in
                    Task { await simulators.setIntegration(enabled: enabled, for: simulator.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(simulator.isBusy)
            .help("Load the Voly agent into apps launched in this simulator — from Xcode, the home screen or simctl — without relaunching them. Turning it on restarts the simulator's launch service once; running apps keep running.")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)

        integrationStatus(simulator)

        let peers = session.connections.peers.filter { $0.deviceUDID == simulator.id }
        ForEach(simulator.runningApps) { app in
            if let peer = peers.first(where: { $0.pid == app.pid }) {
                peerRow(peer, subtitle: app.bundleIdentifier)
                    .contextMenu { policyMenu(bundleIdentifier: app.bundleIdentifier) }
            } else {
                uninstrumentedRow(app, simulator: simulator)
            }
        }
        // Agents whose app isn't in the running-apps list (e.g. system apps).
        ForEach(peers.filter { peer in !simulator.runningApps.contains { $0.pid == peer.pid } }) { peer in
            peerRow(peer, subtitle: peer.bundleIdentifier)
        }
    }

    @ViewBuilder
    private func integrationStatus(_ simulator: VolySimulatorManager.Simulator) -> some View {
        if let error = simulator.error {
            caption(error, color: .red)
        } else {
            switch simulator.integration {
            case .inactive:
                caption(
                    simulators.isIntegrationWanted(for: simulator.id)
                        ? "Runtime integration is starting…"
                        : "Runtime integration is off for this simulator.",
                    color: .secondary
                )
            case .active:
                caption(activeDescription, color: .secondary)
            case .paused:
                caption("Runtime integration is paused.", color: .secondary)
            case .unsupported(let reason, _):
                caption("Not supported on this runtime: \(reason)", color: .orange)
            }
        }
    }

    private var activeDescription: String {
        let policy = simulators.policy
        if !policy.allowedBundleIDs.isEmpty {
            return "Integration on for \(policy.allowedBundleIDs.count) selected app(s). Applies from each app's next launch."
        }
        return "Integration on. Apps launched from now on load Voly automatically."
    }

    private func uninstrumentedRow(
        _ app: VolySimulatorManager.RunningAppEntry,
        simulator: VolySimulatorManager.Simulator
    ) -> some View {
        HStack(spacing: 6) {
            Circle().frame(width: 6, height: 6).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.bundleIdentifier).lineLimit(1).truncationMode(.middle)
                Text(uninstrumentedReason(app, simulator: simulator))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Relaunch…") {
                relaunchCandidate = RelaunchCandidate(
                    udid: simulator.id,
                    simulatorName: simulator.device.name,
                    bundleIdentifier: app.bundleIdentifier
                )
            }
            .controlSize(.small)
            .help("Terminate and relaunch this app with the Voly agent. Ends its Xcode debug session.")
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .contextMenu { policyMenu(bundleIdentifier: app.bundleIdentifier) }
    }

    private func uninstrumentedReason(
        _ app: VolySimulatorManager.RunningAppEntry,
        simulator: VolySimulatorManager.Simulator
    ) -> String {
        if app.instrumentsOnNextLaunch {
            return "Not instrumented — started before integration. Available on its next launch."
        }
        if simulator.integration.isActive {
            return "Not instrumented — excluded from integration."
        }
        return "Not instrumented."
    }

    @ViewBuilder
    private func policyMenu(bundleIdentifier: String) -> some View {
        let policy = simulators.policy
        let excluded = policy.excludedBundleIDs.contains(bundleIdentifier)
        let listed = policy.allowedBundleIDs.contains(bundleIdentifier)
        Button(excluded ? "Include in Runtime Integration" : "Exclude from Runtime Integration") {
            simulators.setExcluded(!excluded, bundleIdentifier: bundleIdentifier)
        }
        Button(listed ? "Remove from Instrument-Only List" : "Instrument Only Selected Apps (Add This App)") {
            simulators.setAllowListed(!listed, bundleIdentifier: bundleIdentifier)
        }
        if !policy.allowedBundleIDs.isEmpty {
            Button("Instrument All Apps Again") { simulators.clearAllowList() }
        }
    }

    // MARK: - Peers

    /// Bonjour (SDK-linked) agents and anything not tied to a listed simulator.
    private var otherPeers: [ConnectionManager.Peer] {
        let listed = Set(simulators.simulators.map(\.id))
        return session.connections.peers.filter { peer in
            guard let udid = peer.deviceUDID else { return true }
            return !listed.contains(udid)
        }
    }

    private func peerRow(_ peer: ConnectionManager.Peer, subtitle: String?) -> some View {
        let isActive = session.state.activePeerID == peer.id
        let isConnected = session.state.connectedPeerIDs.contains(peer.id)
        return Button {
            Task { await session.connect(to: peer) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(isActive ? Color.green : (isConnected ? Color.blue : Color.secondary))
                VStack(alignment: .leading, spacing: 0) {
                    Text(peer.displayName).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(isActive ? "Inspecting" : (isConnected ? "Connected" : "Ready"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .help(isActive ? "The inspector is driving this app." : "Inspect this app.")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .textSelection(.enabled)
    }
}
