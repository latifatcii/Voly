import SwiftUI

/// Footer mark that shows while an AI agent is using Voly: lit for a few
/// seconds after each request, so the user can tell when something other
/// than them is reading (or changing) the app.
struct AgentActivityBadge: View {
    let access: MCPService
    /// How long after a request the badge stays lit.
    private static let linger: TimeInterval = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let call = access.lastToolCall, context.date.timeIntervalSince(call.date) < Self.linger {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                    Text("Agent")
                }
                .font(VolyTheme.small)
                .foregroundStyle(VolyTheme.selection)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(VolyTheme.selection.opacity(0.14), in: Capsule())
                .help("An AI agent is using Voly — last request: \(call.name)")
                .transition(.opacity)
            }
        }
    }
}
