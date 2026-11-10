import SwiftUI

struct URLTesterPanel: View {
    @Bindable var session: InspectorSession
    @State private var input: String = ""
    @State private var lastResult: (success: Bool, message: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VolySection("Open a URL in the app") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            VolyTextField("yourapp://path?param=value", text: $input)
                                .onSubmit(fire)
                            Button("Open", action: fire)
                                .buttonStyle(VolyTextButtonStyle())
                                .disabled(input.isEmpty)
                        }
                        if let result = lastResult {
                            Label(result.message, systemImage: result.success ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(VolyTheme.small)
                                .foregroundStyle(result.success ? VolyTheme.ok : VolyTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .volyCard()
                }

                if !session.state.urlHistory.isEmpty {
                    VolySection("History") {
                        VStack(spacing: 0) {
                            let history = Array(session.state.urlHistory.reversed())
                            ForEach(Array(history.enumerated()), id: \.element) { index, url in
                                if index > 0 { VolyTheme.hairline.frame(height: 1) }
                                HStack(spacing: 8) {
                                    Text(url.absoluteString)
                                        .font(VolyTheme.code())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 6)
                                    Button("Open again") {
                                        Task { await fire(url: url) }
                                    }
                                    .buttonStyle(VolyTextButtonStyle())
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                            }
                        }
                        .volyCard(padding: 0)
                    }
                }
            }
            .padding(VolyTheme.gutter)
        }
    }

    private func fire() {
        guard let url = URL(string: input) else {
            lastResult = (false, "That isn't a valid URL.")
            return
        }
        Task { await fire(url: url) }
    }

    private func fire(url: URL) async {
        let (success, err) = await session.openURL(url)
        lastResult = (success, success ? "Opened \(url.absoluteString)" : (err ?? "The app didn't open the URL."))
        if success, !session.state.urlHistory.contains(url) {
            session.state.urlHistory.append(url)
        }
    }
}
