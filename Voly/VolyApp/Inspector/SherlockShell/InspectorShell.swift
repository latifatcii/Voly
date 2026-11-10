import SwiftUI
import VolyHost
import VolyModels
import VolyProtocol

/// The inspector panel: a title bar naming what is selected, icon tabs, the
/// tab's content, and a footer with the connected app and runtime actions.
struct InspectorShell: View {
    @Bindable var session: InspectorSession
    @State private var pane: InspectorPane

    init(session: InspectorSession, initialTab: DetailTab = .hierarchy) {
        self.session = session
        _pane = State(initialValue: InspectorPane(tab: initialTab))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VolyTheme.hairline.frame(height: 1)
            if let status = session.state.actionStatus {
                actionStatusLine(status)
            }
            if session.state.pickModeActive && session.state.selectedViewID == nil {
                pickHint
            }
            if let node = currentNode(), pane.currentTab.isAboutSelection {
                SelectionContextStrip(
                    node: node,
                    measurement: session.measurement,
                    lastSummary: session.lastMeasurementSummary,
                    source: session.state.sourceLookup,
                    onOpenSource: { location in Task { await session.openSource(location) } }
                )
            }
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VolyTheme.hairline.frame(height: 1)
            footer
        }
        .font(VolyTheme.body)
        .foregroundStyle(VolyTheme.text)
        .tint(VolyTheme.selection)
        .background(VolyTheme.panel)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .task { session.connections.startBrowsing() }
        .onChange(of: session.state.selectedViewID) { _, newID in
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
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if session.state.pickModeActive {
                Task { await session.exitPickMode() }
                return .handled
            }
            return .ignored
        }
    }

    // MARK: header

    /// Sits in the window's title bar area: the close button stays where
    /// macOS puts it, the title is centered on the panel.
    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                InspectorTitle(node: currentNode(), fallback: appTitle)
                    .padding(.horizontal, 64)
                HStack {
                    Spacer()
                    if let node = currentNode() {
                        JumpToSourceButton(
                            nodeID: node.id,
                            source: session.state.sourceLookup,
                            action: { Task { await session.jumpToSource() } }
                        )
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 28)
            TopTabBar(pane: pane, hasSelection: session.state.selectedViewID != nil)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(VolyTheme.chrome)
    }

    private var appTitle: String {
        session.state.agent?.processName ?? "Voly"
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle().frame(width: 7, height: 7).foregroundStyle(statusColor)
                Text(statusText)
                    .foregroundStyle(VolyTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let simulator = simulatorName {
                    Text(simulator)
                        .foregroundStyle(VolyTheme.dim)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            .font(VolyTheme.small)
            .help(statusHelp)
            Spacer(minLength: 6)
            RuntimeActionsBar(session: session)
            Button {
                Task {
                    if session.state.pickModeActive { await session.exitPickMode() }
                    else { await session.enterPickMode() }
                }
            } label: {
                Label("Pick", systemImage: "cursorarrow.rays")
            }
            .buttonStyle(VolyIconButtonStyle(isOn: session.state.pickModeActive))
            .keyboardShortcut("m", modifiers: [.control, .option, .command])
            .help(session.state.pickModeActive ? "Exit pick mode (⌃⌥⌘M / Esc)" : "Pick + measure (⌃⌥⌘M)")

            Button {
                Task { await session.refreshHierarchy() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(VolyIconButtonStyle())
            .disabled(session.state.connectionStatus != .connected)
            .help("Reload the view tree")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(VolyTheme.chrome)
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

    // MARK: status

    private var statusText: String {
        switch session.state.connectionStatus {
        case .disconnected: return "No app connected"
        case .connecting: return "Connecting…"
        case .connected:
            return session.state.agent?.processName ?? "Connected"
        }
    }

    private var statusColor: Color {
        switch session.state.connectionStatus {
        case .disconnected: return VolyTheme.faint
        case .connecting: return VolyTheme.warning
        case .connected: return VolyTheme.ok
        }
    }

    /// The simulator the inspected app runs in, by its device name.
    private var simulatorName: String? {
        guard session.state.connectionStatus == .connected,
              let udid = session.activeSimulatorUDID
        else { return nil }
        return session.simulators.simulators.first { $0.id == udid }?.device.name
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
        return parts.joined(separator: ", ")
    }

    private var pickHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.click")
                .foregroundStyle(VolyTheme.selection)
            Text("Click a view in a simulator to select it. Hover another to measure.")
                .foregroundStyle(VolyTheme.dim)
            Spacer(minLength: 0)
        }
        .font(VolyTheme.small)
        .padding(.horizontal, VolyTheme.gutter + 2)
        .padding(.vertical, 6)
        .background(VolyTheme.selection.opacity(0.08))
    }

    private func actionStatusLine(_ status: ActionStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(status.isError ? VolyTheme.warning : VolyTheme.ok)
            Text(status.message)
                .foregroundStyle(VolyTheme.text)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                session.state.actionStatus = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(VolyTheme.dim)
            .help("Dismiss")
        }
        .font(VolyTheme.small)
        .padding(.horizontal, VolyTheme.gutter + 2)
        .padding(.vertical, 6)
        .background(VolyTheme.card)
    }
}
