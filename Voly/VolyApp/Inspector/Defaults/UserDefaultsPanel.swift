import SwiftUI
import VolyModels
import VolyCodables
import VolyProtocol

struct UserDefaultsPanel: View {
    @Bindable var session: InspectorSession
    @State private var suite = ""
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VolySection("Suite") {
                        HStack(spacing: 8) {
                            VolyTextField("Standard defaults", text: $suite)
                                .onSubmit(load)
                            Button("Load", action: load)
                                .buttonStyle(VolyTextButtonStyle())
                        }
                        .volyCard()
                    }
                    VolySection("Keys") {
                        Text("\(session.state.userDefaults.count)")
                            .font(VolyTheme.code(10.5))
                            .foregroundStyle(VolyTheme.faint)
                    } content: {
                        if session.state.userDefaults.isEmpty {
                            Text("Load a suite to see its keys.")
                                .font(VolyTheme.small)
                                .foregroundStyle(VolyTheme.dim)
                                .volyCard()
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(session.state.userDefaults.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { VolyTheme.hairline.frame(height: 1) }
                                    row(item)
                                }
                            }
                            .volyCard(padding: 0)
                        }
                    }
                }
                .padding(VolyTheme.gutter)
            }
            VolyTheme.hairline.frame(height: 1)
            addRow
        }
    }

    private func row(_ item: UserDefaultsItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.key)
                    .font(VolyTheme.code())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(describe(item.value))
                    .font(VolyTheme.code(11))
                    .foregroundStyle(VolyTheme.dim)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            VolyChip(text: item.type.rawValue)
            Button(role: .destructive) {
                Task { await session.deleteUserDefault(suite: item.suite.isEmpty ? nil : item.suite, key: item.key) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(VolyTheme.dim)
            }
            .buttonStyle(.plain)
            .help("Delete \(item.key)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            VolyTextField("Key", text: $newKey)
            VolyTextField("Value", text: $newValue).onSubmit(save)
            Button("Save", action: save)
                .buttonStyle(VolyTextButtonStyle())
                .disabled(newKey.isEmpty)
                .help("Add the key, or replace its value")
        }
        .padding(VolyTheme.gutter)
        .background(VolyTheme.chrome.opacity(0.55))
    }

    private func load() {
        Task { await session.listUserDefaults(suite: suite.isEmpty ? nil : suite) }
    }

    private func save() {
        guard !newKey.isEmpty else { return }
        let suiteValue = suite.isEmpty ? nil : suite
        let request = UserDefaultsSetRequest(suite: suiteValue, key: newKey, value: bestValue(for: newValue))
        Task {
            await session.setUserDefault(request)
            newKey = ""
            newValue = ""
        }
    }

    private func bestValue(for text: String) -> PropValue {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let i = Int64(text) { return .int(i) }
        if let d = Double(text) { return .double(d) }
        return .string(text)
    }

    private func describe(_ v: PropValue) -> String {
        switch v {
        case .null: return "nil"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return "\"\(s)\""
        case .url(let u): return u.absoluteString
        case .color: return "(color)"
        case .rect(let r): return "[\(r.x), \(r.y), \(r.width), \(r.height)]"
        case .size(let s): return "(\(s.width) × \(s.height))"
        case .point(let p): return "(\(p.x), \(p.y))"
        case .arrayOf(let a): return "[\(a.count) items]"
        case .dictOf(let d): return "{\(d.count) keys}"
        }
    }
}
