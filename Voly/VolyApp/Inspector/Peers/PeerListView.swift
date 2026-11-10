import SwiftUI
import VolyHost

/// The Simulators tab's content: booted simulators with their runtime-integration
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
        VStack(alignment: .leading, spacing: 14) {
            VolySection("Simulators") {
                Toggle("All simulators", isOn: Binding(
                    get: { simulators.preference.allSimulators },
                    set: { all in Task { await simulators.setIntegratesAllSimulators(all) } }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(VolyTheme.small)
                .foregroundStyle(VolyTheme.dim)
                .help("Integrate with every booted simulator automatically. Switch a simulator off below to leave it alone, or uncheck this to pick simulators by hand.")
            } content: {
                if let error = simulators.stagingError {
                    caption(error, color: VolyTheme.danger)
                }
                if let error = simulators.discoveryError {
                    caption(error, color: VolyTheme.warning)
                } else if simulators.simulators.isEmpty {
                    caption("No booted simulators. Boot one and it appears here.", color: VolyTheme.dim)
                        .volyCard()
                }
                ForEach(simulators.simulators) { simulator in
                    simulatorCard(simulator)
                }
            }

            let others = otherPeers
            if !others.isEmpty {
                VolySection("Other agents") {
                    VStack(spacing: 0) {
                        ForEach(others) { peer in
                            peerRow(peer, subtitle: nil)
                        }
                    }
                    .volyCard(padding: 4)
                }
            }

            manualConnect
        }
        .padding(VolyTheme.gutter)
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

    private var manualConnect: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showManual.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showManual ? 90 : 0))
                    Text("Manual connect")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(VolyTheme.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)

            if showManual {
                VStack(alignment: .leading, spacing: 6) {
                    VolyRow(label: "Host", labelWidth: 44) {
                        VolyTextField("127.0.0.1", text: $manualHost)
                    }
                    VolyRow(label: "Port", labelWidth: 44) {
                        HStack(spacing: 8) {
                            VolyTextField("51234", text: $manualPort).frame(width: 90)
                            Button("Connect") {
                                if let p = UInt16(manualPort) {
                                    Task { await session.connectManually(host: manualHost, port: p) }
                                }
                            }
                            .buttonStyle(VolyTextButtonStyle())
                            .disabled(UInt16(manualPort) == nil || manualHost.isEmpty)
                        }
                    }
                }
                .volyCard()
            }
        }
    }

    // MARK: - Simulator

    private func simulatorCard(_ simulator: VolySimulatorManager.Simulator) -> some View {
        let peers = session.connections.peers.filter { $0.deviceUDID == simulator.id }
        let strays = peers.filter { peer in !simulator.runningApps.contains { $0.pid == peer.pid } }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 15))
                    .foregroundStyle(simulator.integration.isActive ? VolyTheme.text : VolyTheme.dim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(simulator.device.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(simulator.runtimeName)
                        .font(VolyTheme.small)
                        .foregroundStyle(VolyTheme.dim)
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
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 6)

            integrationStatus(simulator)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ForEach(simulator.runningApps) { app in
                VolyTheme.hairline.frame(height: 1)
                if let peer = peers.first(where: { $0.pid == app.pid }) {
                    peerRow(peer, subtitle: app.bundleIdentifier)
                        .contextMenu { policyMenu(bundleIdentifier: app.bundleIdentifier) }
                } else {
                    uninstrumentedRow(app, simulator: simulator)
                }
            }
            // Agents whose app isn't in the running-apps list (e.g. system apps).
            ForEach(strays) { peer in
                VolyTheme.hairline.frame(height: 1)
                peerRow(peer, subtitle: peer.bundleIdentifier)
            }
        }
        .volyCard(padding: 0)
    }

    @ViewBuilder
    private func integrationStatus(_ simulator: VolySimulatorManager.Simulator) -> some View {
        if let error = simulator.error {
            caption(error, color: VolyTheme.danger)
        } else {
            switch simulator.integration {
            case .inactive:
                caption(
                    simulators.isIntegrationWanted(for: simulator.id)
                        ? "Runtime integration is starting…"
                        : "Runtime integration is off for this simulator.",
                    color: VolyTheme.dim
                )
            case .active:
                caption(activeDescription, color: VolyTheme.dim)
            case .paused:
                caption("Runtime integration is paused.", color: VolyTheme.dim)
            case .unsupported(let reason, _):
                caption("Not supported on this runtime: \(reason)", color: VolyTheme.warning)
            }
        }
    }

    private var activeDescription: String {
        let policy = simulators.policy
        if !policy.allowedBundleIDs.isEmpty {
            return "On for \(policy.allowedBundleIDs.count) selected app(s), from each app's next launch."
        }
        return "Apps launched from now on load Voly automatically."
    }

    private func uninstrumentedRow(
        _ app: VolySimulatorManager.RunningAppEntry,
        simulator: VolySimulatorManager.Simulator
    ) -> some View {
        HStack(spacing: 8) {
            Circle().strokeBorder(VolyTheme.faint, lineWidth: 1).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.bundleIdentifier)
                    .font(VolyTheme.code(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(uninstrumentedReason(app, simulator: simulator))
                    .font(.system(size: 10.5))
                    .foregroundStyle(VolyTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Relaunch…") {
                relaunchCandidate = RelaunchCandidate(
                    udid: simulator.id,
                    simulatorName: simulator.device.name,
                    bundleIdentifier: app.bundleIdentifier
                )
            }
            .buttonStyle(VolyTextButtonStyle())
            .help("Terminate and relaunch this app with the Voly agent. Ends its Xcode debug session.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contextMenu { policyMenu(bundleIdentifier: app.bundleIdentifier) }
    }

    private func uninstrumentedReason(
        _ app: VolySimulatorManager.RunningAppEntry,
        simulator: VolySimulatorManager.Simulator
    ) -> String {
        if app.instrumentsOnNextLaunch {
            return "Started before integration. Inspectable from its next launch."
        }
        if simulator.integration.isActive {
            return "Excluded from integration."
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
            HStack(spacing: 8) {
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(isActive ? VolyTheme.ok : (isConnected ? VolyTheme.selection : VolyTheme.faint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.displayName)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(VolyTheme.code(10.5))
                            .foregroundStyle(VolyTheme.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if isActive {
                    VolyChip(text: "Inspecting", color: VolyTheme.ok)
                } else {
                    Text(isConnected ? "Connected" : "Ready")
                        .font(.system(size: 10.5))
                        .foregroundStyle(VolyTheme.dim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isActive ? VolyTheme.ok.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "The inspector is showing this app." : "Inspect this app.")
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
