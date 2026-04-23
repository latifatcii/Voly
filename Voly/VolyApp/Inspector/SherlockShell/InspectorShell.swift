import SwiftUI
import VolyModels

struct InspectorShell: View {
    @Bindable var session: InspectorSession
    @State private var pane = InspectorPane()

    var body: some View {
        VStack(spacing: 0) {
            topStatusBar
            Divider()
            if session.state.measureModeActive && session.state.selectedViewID == nil {
                Label("Click a view on the simulator to anchor", systemImage: "cursorarrow.click")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            if let node = currentNode(), pane.currentTab.requiresSelection {
                DetailHeader(node: node, pane: pane, measurement: session.measurement,
                             lastSummary: session.lastMeasurementSummary)
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
            if newID != nil, pane.currentTab == .hierarchy {
                pane.currentTab = .layout
            }
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
            if session.state.measureModeActive {
                Task { await session.exitMeasureMode() }
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
            }
            Spacer()
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
            .disabled(session.state.connectionStatus != .connected)

            Button {
                Task {
                    if session.state.measureModeActive { await session.exitMeasureMode() }
                    else { await session.enterMeasureMode() }
                }
            } label: {
                Label("Measure", systemImage: session.state.measureModeActive
                      ? "ruler.fill"
                      : "ruler")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("m", modifiers: [.control, .option, .command])
            .disabled(session.state.connectionStatus != .connected)
            .help(session.state.measureModeActive ? "Exit measure mode (⌃⌥⌘M / Esc)" : "Measure (⌃⌥⌘M)")

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
        case .hierarchy:
            HierarchyTab(session: session, measurement: session.measurement)
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
        case .src:
            if session.state.selectedViewID != nil {
                SourceNavigationPanel(session: session)
            } else {
                NoSelectionView()
            }
        case .userDefaults:
            UserDefaultsPanel(session: session)
        case .urlTester:
            URLTesterPanel(session: session)
        case .preview:
            PreviewControlPanel(session: session)
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
        case .connected: return "Connected"
        }
    }

    private var statusColor: Color {
        switch session.state.connectionStatus {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        }
    }
}
