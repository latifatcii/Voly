import SwiftUI

struct PeerListView: View {
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
