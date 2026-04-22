import SwiftUI
import VolyModels

struct InspectorShell: View {
    @Bindable var session: InspectorSession
    @State private var pane = InspectorPane()

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { pane.sidebarVisible ? .all : .detailOnly },
            set: { newValue in
                pane.sidebarVisible = (newValue != .detailOnly)
            }
        )) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 320)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        }
        .toolbar { toolbar }
        .task { session.connections.startBrowsing() }
        .onChange(of: session.state.selectedViewID) { _, newID in
            pane.resetInheritance(for: newID)
        }
    }

    // MARK: sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            PeerListView(session: session)
            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .textSelection(.enabled)
            }
            Divider()
            HierarchyBrowser(session: session)
        }
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let node = currentNode() {
                DetailHeader(node: node, pane: pane)
            }
            TopTabBar(pane: pane, hasSelection: session.state.selectedViewID != nil)
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch pane.currentTab {
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

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                pane.sidebarVisible.toggle()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut("0", modifiers: [.command])
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Circle().frame(width: 8, height: 8).foregroundStyle(statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItemGroup {
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
            .disabled(session.state.connectionStatus != .connected)

            Button {
                Task { await session.refreshHierarchy() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(session.state.connectionStatus != .connected)
        }
    }

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
