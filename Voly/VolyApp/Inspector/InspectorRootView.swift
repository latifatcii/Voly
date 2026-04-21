import SwiftUI
import VolyModels

struct InspectorRootView: View {
    @Bindable var session: InspectorSession
    @State private var sidebarSelection: SidebarItem = .hierarchy
    @State private var showAttachSheet: Bool = false

    enum SidebarItem: Hashable {
        case hierarchy, userDefaults, urlTester, preview
    }

    private var bundledDylibURL: URL? {
        Bundle.main.url(forResource: "VolyAgent", withExtension: "dylib")
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            centerColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
            detailColumn
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        }
        .toolbar { toolbarContent }
        .task { session.connections.startBrowsing() }
        .sheet(isPresented: $showAttachSheet) {
            if let url = bundledDylibURL {
                AppPickerSheet(dylibURL: url)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "xmark.octagon")
                    Text("VolyAgent.dylib not found in app bundle")
                    Button("Close") { showAttachSheet = false }
                }
                .padding(24)
            }
        }
    }

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
            if let browserError = session.connections.lastError {
                Label(browserError, systemImage: "wifi.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(8)
                    .textSelection(.enabled)
            }
            Divider()
            List(selection: $sidebarSelection) {
                Label("Hierarchy", systemImage: "rectangle.3.group").tag(SidebarItem.hierarchy)
                Label("UserDefaults", systemImage: "tray").tag(SidebarItem.userDefaults)
                Label("URL Tester", systemImage: "link").tag(SidebarItem.urlTester)
                Label("Preview", systemImage: "aspectratio").tag(SidebarItem.preview)
            }
        }
    }

    @ViewBuilder
    private var centerColumn: some View {
        switch sidebarSelection {
        case .hierarchy:
            HierarchyBrowser(session: session)
        case .userDefaults:
            UserDefaultsPanel(session: session)
        case .urlTester:
            URLTesterPanel(session: session)
        case .preview:
            PreviewControlPanel(session: session)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if session.state.selectedViewID != nil {
            TabView {
                PropertyPanel(session: session)
                    .tabItem { Label("Properties", systemImage: "slider.horizontal.3") }
                ConstraintEditor(session: session)
                    .tabItem { Label("Constraints", systemImage: "rectangle.stack") }
                SourceNavigationPanel(session: session)
                    .tabItem { Label("Source", systemImage: "doc.text") }
            }
            .padding(.top, 2)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "cursorarrow.square",
                description: Text("Select a view in the hierarchy to inspect its properties.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                showAttachSheet = true
            } label: {
                Label("Attach", systemImage: "arrow.down.right.square")
            }
            .disabled(bundledDylibURL == nil)

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

private struct PeerListView: View {
    @Bindable var session: InspectorSession
    @State private var manualHost: String = "127.0.0.1"
    @State private var manualPort: String = ""
    @State private var showManual: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Discovered Apps")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            if session.connections.peers.isEmpty {
                Text("Scanning for VolyAgent-enabled apps…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            ForEach(session.connections.peers) { peer in
                Button {
                    Task { await session.connect(to: peer) }
                } label: {
                    HStack {
                        Image(systemName: "iphone")
                        Text(peer.displayName).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
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
    }
}
