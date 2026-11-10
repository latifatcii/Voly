import SwiftUI
import VolyHost
import VolyModels

/// The panel's title: the selected view's class, with its inheritance chain
/// one click away. With nothing selected it names the app being inspected.
struct InspectorTitle: View {
    let node: ViewNode?
    let fallback: String

    var body: some View {
        if let node, let chain = node.classInheritance, chain.count > 1 {
            Menu {
                Section("Inherits from") {
                    ForEach(Array(chain.dropFirst().enumerated()), id: \.offset) { _, name in
                        Button(name) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(name, forType: .string)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(node.className)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(VolyTheme.dim)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(VolyTheme.title)
            .foregroundStyle(VolyTheme.text)
            .help("Inheritance chain (choose a class to copy its name)")
        } else {
            Text(node?.className ?? fallback)
                .font(VolyTheme.title)
                .foregroundStyle(node == nil ? VolyTheme.dim : VolyTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Jump to Source, in the title bar next to the class it applies to.
struct JumpToSourceButton: View {
    let nodeID: ObjectID
    let source: SourceLookupState
    let action: () -> Void

    var body: some View {
        if case .resolving(nodeID) = source {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 22)
        } else {
            Button(action: action) {
                Label("Jump to Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(VolyIconButtonStyle())
            .keyboardShortcut("j", modifiers: [.control, .option, .command])
            .help("Jump to Source in Xcode (⌃⌥⌘J)")
        }
    }
}

/// What Voly knows about the current selection beyond its properties: where
/// its source is, and how far it is from the view being measured against.
/// Collapses to nothing when there is neither.
struct SelectionContextStrip: View {
    let node: ViewNode
    @Bindable var measurement: MeasurementPane
    let lastSummary: MeasurementSummary?
    /// What distances are counted in: `pt`, or `dp` for an Android app.
    var unit = "pt"
    let source: SourceLookupState
    let onOpenSource: (SourceLocation) -> Void

    private var lookup: SourceLookup? {
        if case .resolved(node.id, let lookup) = source { return lookup }
        return nil
    }

    private var showsMeasurement: Bool {
        measurement.effectiveOtherID != nil && lastSummary != nil
    }

    var body: some View {
        if lookup != nil || showsMeasurement {
            VStack(alignment: .leading, spacing: 4) {
                if showsMeasurement, let lastSummary {
                    measurementLine(lastSummary)
                }
                if let lookup {
                    sourceLines(lookup)
                }
            }
            .padding(.horizontal, VolyTheme.gutter + 2)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VolyTheme.chrome.opacity(0.55))
            .overlay(alignment: .bottom) { VolyTheme.hairline.frame(height: 1) }
        }
    }

    // MARK: Measurement

    private func measurementLine(_ summary: MeasurementSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ruler")
                .font(.system(size: 10))
                .foregroundStyle(VolyTheme.measurement)
            Text(Self.summaryText(summary, unit: unit))
                .font(VolyTheme.code(11))
                .foregroundStyle(VolyTheme.text)
            Spacer(minLength: 0)
            Button {
                measurement.pinnedID = nil
            } label: {
                Image(systemName: measurement.pinnedID != nil ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(measurement.pinnedID != nil ? VolyTheme.measurement : VolyTheme.dim)
            }
            .buttonStyle(.plain)
            .help(measurement.pinnedID != nil ? "Unpin measurement" : "Measurement is transient")
        }
    }

    /// - Parameter unit: `pt`, or `dp` for an Android app.
    private static func summaryText(_ s: MeasurementSummary, unit: String) -> String {
        switch s.kind {
        case .sameView:    return "same view"
        case .overlap:     return "overlap"
        case .crossWindow: return "different windows"
        case .sideBySide, .containment:
            var parts: [String] = []
            if let h = s.horizontal { parts.append("↔ \(Int(h.rounded())) \(unit)") }
            if let v = s.vertical   { parts.append("↕ \(Int(v.rounded())) \(unit)") }
            return parts.joined(separator: "   ")
        }
    }

    // MARK: Source

    /// File, line, module and how the answer was obtained — or why there is
    /// none. Several rows mean several candidates; clicking one opens it.
    @ViewBuilder
    private func sourceLines(_ lookup: SourceLookup) -> some View {
        ForEach(lookup.locations) { location in
            Button {
                onOpenSource(location)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(VolyTheme.selection)
                    Text(location.line.map { "\(location.fileName):\($0)" } ?? location.fileName)
                        .font(VolyTheme.code(11))
                        .foregroundStyle(VolyTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(Self.detail(for: location))
                        .font(.system(size: 10.5))
                        .foregroundStyle(VolyTheme.dim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(location.path)
        }
        if let note = lookup.note {
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(lookup.locations.isEmpty ? VolyTheme.warning : VolyTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if lookup.isAmbiguous {
            Text("Several files match — choose one to open it.")
                .font(.system(size: 10.5))
                .foregroundStyle(VolyTheme.dim)
        }
    }

    private static func detail(for location: SourceLocation) -> String {
        var parts: [String] = []
        switch location.role {
        case .viewClass, nil: parts.append(location.className)
        case .superclass: parts.append("superclass \(location.className)")
        case .viewController: parts.append("controller \(location.className)")
        case .ancestorView: parts.append("container \(location.className)")
        }
        if let module = location.moduleName { parts.append("in \(module)") }
        switch (location.method, location.lineOrigin) {
        case (.debugInfo, .declaration): parts.append("declaration")
        case (.debugInfo, .method(let name)): parts.append(name)
        case (.debugInfo, .fileOnly): parts.append("file only")
        case (.spotlight, .fileOnly): parts.append("matched by file name, no line")
        case (.spotlight, _): parts.append("matched by file name")
        }
        return parts.joined(separator: ", ")
    }
}
