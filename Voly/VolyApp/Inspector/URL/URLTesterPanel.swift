import SwiftUI

struct URLTesterPanel: View {
    @Bindable var session: InspectorSession
    @State private var input: String = ""
    @State private var lastResult: (success: Bool, message: String)?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open URL on Device").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("yourapp://path?param=value", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(fire)
                    Button("Fire") { fire() }.disabled(input.isEmpty)
                }
                if let result = lastResult {
                    Label(result.message, systemImage: result.success ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(result.success ? .green : .red)
                }
            }
            .padding(10)
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("History").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                List(session.state.urlHistory.reversed(), id: \.self) { url in
                    HStack {
                        Text(url.absoluteString).fontDesign(.monospaced).font(.caption)
                        Spacer()
                        Button("Replay") {
                            Task { await fire(url: url) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func fire() {
        guard let url = URL(string: input) else {
            lastResult = (false, "Invalid URL.")
            return
        }
        Task { await fire(url: url) }
    }

    private func fire(url: URL) async {
        let (success, err) = await session.openURL(url)
        lastResult = (success, success ? "Opened \(url.absoluteString)" : (err ?? "Failed."))
        if success, !session.state.urlHistory.contains(url) {
            session.state.urlHistory.append(url)
        }
    }
}
