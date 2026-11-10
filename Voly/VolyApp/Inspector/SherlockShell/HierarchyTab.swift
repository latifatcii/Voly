import SwiftUI

/// Contents of the "Sims" tab: booted simulators, their integration switch,
/// the apps running in them, and manual connect.
struct SimulatorsTab: View {
    @Bindable var session: InspectorSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PeerListView(session: session)
                SessionErrorLabel(session: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Contents of the "Tree" (Hierarchy) tab: the view hierarchy of the app
/// being inspected.
struct HierarchyTab: View {
    @Bindable var session: InspectorSession
    @Bindable var measurement: MeasurementPane
    /// Jump to the Sims tab, offered when there is nothing to show here.
    let onShowSimulators: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SessionErrorLabel(session: session)
            if session.state.connectionStatus == .disconnected {
                ContentUnavailableView {
                    Label("No App Connected", systemImage: "rectangle.3.group")
                } description: {
                    Text("Run an app in a booted simulator and it shows up here.")
                } actions: {
                    Button("Show Simulators", action: onShowSimulators)
                }
            } else {
                HierarchyBrowser(session: session, measurement: measurement)
            }
        }
    }
}

/// The session's latest error, shown wherever the user is likely to be
/// looking when it happens.
private struct SessionErrorLabel: View {
    @Bindable var session: InspectorSession

    var body: some View {
        if let error = session.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
