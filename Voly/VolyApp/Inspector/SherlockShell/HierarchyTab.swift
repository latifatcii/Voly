import SwiftUI

/// Contents of the Simulators tab: booted simulators, their integration
/// switch, the apps running in them, and manual connect.
struct SimulatorsTab: View {
    @Bindable var session: InspectorSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SessionErrorLabel(session: session)
                PeerListView(session: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Contents of the View Tree tab: the view hierarchy of the app being
/// inspected.
struct HierarchyTab: View {
    @Bindable var session: InspectorSession
    @Bindable var measurement: MeasurementPane
    /// Jump to the Simulators tab, offered when there is nothing to show here.
    let onShowSimulators: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SessionErrorLabel(session: session)
            if session.state.connectionStatus == .disconnected {
                VolyEmptyState(
                    symbol: "rectangle.3.group",
                    title: "No app connected",
                    message: "Run an app in a booted simulator and its views show up here.",
                    actionTitle: "Show Simulators",
                    action: onShowSimulators
                )
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(VolyTheme.warning)
            .padding(.horizontal, VolyTheme.gutter + 2)
            .padding(.vertical, 7)
            .background(VolyTheme.warning.opacity(0.08))
        }
    }
}
