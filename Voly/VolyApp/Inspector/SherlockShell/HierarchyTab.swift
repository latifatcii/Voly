import SwiftUI

/// Contents of the "Tree" (Hierarchy) tab. Shows the peer list and any
/// connection errors at the top, then the hierarchy browser below.
struct HierarchyTab: View {
    @Bindable var session: InspectorSession
    @Bindable var measurement: MeasurementPane

    var body: some View {
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
            HierarchyBrowser(session: session, measurement: measurement)
        }
    }
}
