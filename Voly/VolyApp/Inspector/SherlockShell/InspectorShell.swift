import SwiftUI
import VolyModels
import VolyProtocol

struct InspectorShell: View {
    @Bindable var session: InspectorSession
    @State private var pane = InspectorPane()

    var body: some View {
        VStack(spacing: 0) {
            topStatusBar
            if let status = session.state.actionStatus {
                actionStatusLine(status)
            }
            Divider()
            if session.state.pickModeActive && session.state.selectedViewID == nil {
                Label("Click a view on the simulator to select; hover others to measure",
                      systemImage: "cursorarrow.click")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if let node = currentNode(), pane.currentTab.requiresSelection {
                DetailHeader(node: node, pane: pane, measurement: session.measurement,
                             lastSummary: session.lastMeasurementSummary,
                             source: session.state.sourceLookup,
                             onJumpToSource: { Task { await session.jumpToSource() } },
                             onOpenSource: { location in Task { await session.openSource(location) } })
            }
            TopTabBar(pane: pane, hasSelection: session.state.selectedViewID != nil)
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { session.connections.startBrowsing() }
        .onChange(of: session.state.selectedViewID) { _, newID in
            pane.resetInheritance(for: newID)
            session.measurement.reset()
            session.scheduleMeasurementUpdate(
                anchor: newID,
                other: session.measurement.effectiveOtherID
            )
        }
        .onChange(of: session.measurement.effectiveOtherID) { _, newOther in
            session.scheduleMeasurementUpdate(
                anchor: session.state.selectedViewID,
                other: newOther
            )
        }
        .focusable()
        .onKeyPress(.escape) {
            if session.state.pickModeActive {
                Task { await session.exitPickMode() }
                return .handled
            }
            return .ignored
        }
    }

    // MARK: top status bar

    @ViewBuilder
    private var topStatusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().frame(width: 8, height: 8).foregroundStyle(statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(statusHelp)
            }
            Spacer()
            RuntimeActionsBar(session: session)
            Button {
                Task {
                    if session.state.pickModeActive { await session.exitPickMode() }
                    else { await session.enterPickMode() }
                }
            } label: {
                Label("Pick", systemImage: session.state.pickModeActive
                      ? "cursorarrow.click.2"
                      : "cursorarrow.rays")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("m", modifiers: [.control, .option, .command])
            .disabled(session.state.connectionStatus != .connected)
            .help(session.state.pickModeActive ? "Exit pick mode (⌃⌥⌘M / Esc)" : "Pick + measure (⌃⌥⌘M)")

            Button {
                Task { await session.refreshHierarchy() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(session.state.connectionStatus != .connected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: tab content

    @ViewBuilder
    private var tabContent: some View {
        switch pane.currentTab {
        case .simulators:
            SimulatorsTab(session: session)
        case .hierarchy:
            HierarchyTab(session: session, measurement: session.measurement,
                         onShowSimulators: { pane.currentTab = .simulators })
        case .layout:
            if session.state.selectedViewID != nil {
                LayoutTab(session: session)
            } else {
                NoSelectionView()
            }
        case .props:
            if session.state.selectedViewID != nil {
                PropertyPanel(session: session)
            } else {
                NoSelectionView()
            }
        case .userDefaults:
            UserDefaultsPanel(session: session)
        case .urlTester:
            URLTesterPanel(session: session)
        }
    }

    private func currentNode() -> ViewNode? {
        guard let id = session.state.selectedViewID else { return nil }
        return session.state.findNode(id: id)
    }

    // MARK: status text + color

    private var statusText: String {
        switch session.state.connectionStatus {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected:
            return session.state.agent?.processName ?? "Connected"
        }
    }

    /// Which process the inspector is talking to, and how its agent got there.
    private var statusHelp: String {
        guard session.state.connectionStatus == .connected, let agent = session.state.agent else {
            return statusText
        }
        var parts = [agent.bundleIdentifier ?? agent.processName]
        if let pid = agent.pid { parts.append("pid \(pid)") }
        if let udid = agent.simulatorUDID { parts.append("simulator \(udid)") }
        if let capabilities = agent.capabilities {
            parts.append(capabilities.injectionMode == .injected ? "agent loaded automatically" : "agent linked into the app")
            if !capabilities.previewHost {
                parts.append("resizable preview needs VolyAgent.wrap in the app")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func actionStatusLine(_ status: ActionStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(status.isError ? .orange : .green)
            Text(status.message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                session.state.actionStatus = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var statusColor: Color {
        switch session.state.connectionStatus {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        }
    }
}
