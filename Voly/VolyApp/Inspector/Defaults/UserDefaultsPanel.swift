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
            HStack {
                TextField("Suite name (blank = standard)", text: $suite)
                    .textFieldStyle(.roundedBorder)
                Button("Load") { Task { await session.listUserDefaults(suite: suite.isEmpty ? nil : suite) } }
            }
            .padding(8)
            Divider()

            Table(session.state.userDefaults) {
                TableColumn("Key") { item in
                    Text(item.key).fontDesign(.monospaced).font(.caption)
                }
                .width(min: 140, ideal: 220)
                TableColumn("Type") { item in
                    Text(item.type.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("Value") { item in
                    Text(describe(item.value)).font(.caption)
                }
                TableColumn("") { item in
                    Button(role: .destructive) {
                        Task { await session.deleteUserDefault(suite: item.suite.isEmpty ? nil : item.suite, key: item.key) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
                .width(24)
            }
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Add / replace key").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("key", text: $newKey).textFieldStyle(.roundedBorder)
                    TextField("value", text: $newValue).textFieldStyle(.roundedBorder)
                    Button("Save") { save() }.disabled(newKey.isEmpty)
                }
            }
            .padding(8)
        }
    }

    private func save() {
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
        case .null: return "—"
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
