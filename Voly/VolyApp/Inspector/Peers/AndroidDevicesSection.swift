import SwiftUI
import VolyHost

/// The Android part of the Simulators tab: each emulator (or device adb can
/// reach) with its switch and the user's apps running on it.
///
/// Shown only while there is a device to show, so someone who doesn't use
/// Android never sees it.
struct AndroidDevicesSection: View {
    @Bindable var session: InspectorSession
    @State private var relaunchCandidate: RelaunchCandidate?

    private struct RelaunchCandidate: Identifiable {
        let serial: String
        let deviceName: String
        let package: String
        var id: String { "\(serial):\(package)" }
    }

    private var android: AndroidDeviceManager { session.android }

    var body: some View {
        let snapshot = android.snapshot
        if !snapshot.devices.isEmpty || snapshot.error != nil {
            VolySection("Android") {
                if let error = android.setupError {
                    caption(error, color: VolyTheme.danger)
                }
                if let error = snapshot.error {
                    caption(error, color: VolyTheme.warning)
                }
                ForEach(snapshot.devices) { status in
                    deviceCard(status)
                }
            }
            .confirmationDialog(
                "Restart \(relaunchCandidate?.package ?? "")?",
                isPresented: Binding(get: { relaunchCandidate != nil }, set: { if !$0 { relaunchCandidate = nil } }),
                presenting: relaunchCandidate
            ) { candidate in
                Button("Restart") {
                    Task {
                        do {
                            try await android.relaunch(package: candidate.package, on: candidate.serial)
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { candidate in
                Text("The app on \(candidate.deviceName) is stopped and started again. Its current state is lost and an attached debugger is disconnected.")
            }
        }
    }

    // MARK: - Device

    private func deviceCard(_ status: AndroidDeviceStatus) -> some View {
        let device = status.device
        let peers = session.connections.peers.filter { $0.androidSerial == device.serial }
        let isBusy = android.busySerials.contains(device.serial)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "smartphone")
                    .font(.system(size: 15))
                    .foregroundStyle(status.isIntegrationEnabled ? VolyTheme.text : VolyTheme.dim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text("\(device.runtimeName) · \(device.isEmulator ? "emulator" : "device")")
                        .font(VolyTheme.small)
                        .foregroundStyle(VolyTheme.dim)
                }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Toggle("Inspect apps", isOn: Binding(
                    get: { status.isIntegrationEnabled },
                    set: { enabled in
                        Task { await android.setEnabled(enabled, for: device.serial) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isBusy)
                .help("Attach the Voly agent to debuggable apps running on this device. Apps keep running: nothing is installed and nothing is relaunched.")
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 6)

            deviceStatus(status)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ForEach(status.apps) { app in
                VolyTheme.hairline.frame(height: 1)
                if let peer = peers.first(where: { $0.pid == app.pid }) {
                    peerRow(peer, subtitle: app.package)
                        .contextMenu { policyMenu(package: app.package, device: device) }
                } else {
                    uninspectableRow(app, device: device)
                }
            }
        }
        .volyCard(padding: 0)
    }

    @ViewBuilder
    private func deviceStatus(_ status: AndroidDeviceStatus) -> some View {
        if let error = status.error {
            caption(error, color: VolyTheme.danger)
        } else if !status.isIntegrationEnabled {
            caption("Voly is off for this device.", color: VolyTheme.dim)
        } else if status.apps.isEmpty {
            caption("No app of yours is running. Debug builds are picked up when they start.", color: VolyTheme.dim)
        } else {
            caption("Debug builds running here are inspectable.", color: VolyTheme.dim)
        }
    }

    private func uninspectableRow(_ app: AndroidAppStatus, device: AndroidDevice) -> some View {
        HStack(spacing: 8) {
            Circle().strokeBorder(VolyTheme.faint, lineWidth: 1).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.package)
                    .font(VolyTheme.code(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reason(app))
                    .font(.system(size: 10.5))
                    .foregroundStyle(VolyTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if case .failed = app.state {
                Button("Retry") {
                    Task { await android.retry(serial: device.serial) }
                }
                .buttonStyle(VolyTextButtonStyle())
                .help("Try attaching the Voly agent again.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contextMenu { policyMenu(package: app.package, device: device) }
    }

    private func reason(_ app: AndroidAppStatus) -> String {
        switch app.state {
        case .inspectable: return "Connecting…"
        case .notDebuggable: return "Not a debuggable build. Voly inspects debug builds only."
        case .excluded: return "Excluded from integration."
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private func policyMenu(package: String, device: AndroidDevice) -> some View {
        let excluded = session.simulators.policy.excludedBundleIDs.contains(package)
        Button(excluded ? "Include in Runtime Integration" : "Exclude from Runtime Integration") {
            session.simulators.setExcluded(!excluded, bundleIdentifier: package)
            Task { await android.refresh() }
        }
        Button("Restart App…") {
            relaunchCandidate = RelaunchCandidate(serial: device.serial, deviceName: device.displayName, package: package)
        }
    }

    // MARK: - Rows

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
