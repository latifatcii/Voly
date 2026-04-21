import SwiftUI
import VolyModels

struct SourceNavigationPanel: View {
    @Bindable var session: InspectorSession
    @State private var info: SourceInfo?
    @State private var resolvedPath: URL?
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info {
                LabeledValue("Class", value: info.className)
                if let module = info.moduleName {
                    LabeledValue("Module", value: module)
                }
                if let relative = info.guessedRelativePath {
                    LabeledValue("Indexed path", value: relative)
                }
                if let path = resolvedPath {
                    LabeledValue("Resolved", value: path.path)
                    Button("Open in Xcode") { XcodeLauncher.open(url: path) }
                } else {
                    Button(isResolving ? "Resolving…" : "Resolve & open") {
                        Task { await resolveAndOpen() }
                    }
                    .disabled(isResolving)
                }
            } else {
                Text("Select a view to resolve its source file.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(12)
        .task(id: session.state.selectedViewID) {
            guard let id = session.state.selectedViewID else { info = nil; return }
            info = await session.resolveSource(for: id)
            resolvedPath = nil
        }
    }

    private func resolveAndOpen() async {
        guard let info else { return }
        isResolving = true
        defer { isResolving = false }
        if let indexed = info.guessedRelativePath,
           let root = SourceNavigation.shared.workspaceRoot {
            let candidate = root.appending(path: indexed)
            if FileManager.default.fileExists(atPath: candidate.path) {
                resolvedPath = candidate
                XcodeLauncher.open(url: candidate)
                return
            }
        }
        if let found = await SourceNavigation.shared.findFile(named: "\(info.className).swift") {
            resolvedPath = found
            XcodeLauncher.open(url: found)
        }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String
    init(_ label: String, value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).font(.caption).fontDesign(.monospaced)
            Spacer()
        }
    }
}
