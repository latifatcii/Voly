import SwiftUI
import VolyHost
import VolyModels

/// Shows the selected node's class name with a chevron that expands an
/// indented inheritance chain below. Also shows the measurement badge on the
/// trailing edge when a hover or pinned second view is active.
struct DetailHeader: View {
    let node: ViewNode
    @Bindable var pane: InspectorPane
    @Bindable var measurement: MeasurementPane
    let lastSummary: MeasurementSummary?
    let source: SourceLookupState
    let onJumpToSource: () -> Void
    let onOpenSource: (SourceLocation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            sourceResolution
            if pane.isInheritanceExpanded(node.id),
               let chain = node.classInheritance, chain.count > 1 {
                chainList(chain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(node.className)
                .font(.system(size: 18, weight: .semibold))
                .fontDesign(.default)
            if let chain = node.classInheritance, chain.count > 1 {
                Button {
                    pane.toggleInheritance(node.id)
                } label: {
                    Image(systemName: pane.isInheritanceExpanded(node.id)
                          ? "chevron.up"
                          : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show inheritance chain")
            }
            jumpToSourceButton
            Spacer(minLength: 0)
            measurementBadge
        }
    }

    @ViewBuilder
    private var measurementBadge: some View {
        if measurement.effectiveOtherID != nil, let summary = lastSummary {
            HStack(spacing: 6) {
                Text(summaryText(summary))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                Button {
                    measurement.pinnedID = nil
                } label: {
                    Image(systemName: measurement.pinnedID != nil ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(measurement.pinnedID != nil ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(measurement.pinnedID != nil ? "Unpin measurement" : "Measurement is transient")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12), in: Capsule())
        }
    }

    // MARK: Jump to Source

    @ViewBuilder
    private var jumpToSourceButton: some View {
        if case .resolving(node.id) = source {
            ProgressView().controlSize(.small)
        } else {
            Button(action: onJumpToSource) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("j", modifiers: [.control, .option, .command])
            .help("Jump to Source in Xcode (⌃⌥⌘J)")
        }
    }

    /// File, line, module and how the answer was obtained — or why there is
    /// none. Several rows mean several candidates; clicking one opens it.
    @ViewBuilder
    private var sourceResolution: some View {
        if case .resolved(node.id, let lookup) = source {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lookup.locations) { location in
                    Button {
                        onOpenSource(location)
                    } label: {
                        HStack(spacing: 4) {
                            Text(location.line.map { "\(location.fileName):\($0)" } ?? location.fileName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(Self.detail(for: location))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(location.path)
                }
                if let note = lookup.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(lookup.locations.isEmpty ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if lookup.isAmbiguous {
                    Text("Multiple candidates — click one to open it.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
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
        if let module = location.moduleName { parts.append(module) }
        switch (location.method, location.lineOrigin) {
        case (.debugInfo, .declaration): parts.append("debug info · declaration")
        case (.debugInfo, .method(let name)): parts.append("debug info · \(name)")
        case (.debugInfo, .fileOnly): parts.append("debug info · file only")
        case (.spotlight, .fileOnly): parts.append("file name match · no line")
        case (.spotlight, _): parts.append("file name match")
        }
        return parts.joined(separator: " · ")
    }

    private func summaryText(_ s: MeasurementSummary) -> String {
        switch s.kind {
        case .sameView:    return "same view"
        case .overlap:     return "overlap"
        case .crossWindow: return "different windows"
        case .sideBySide, .containment:
            var parts: [String] = []
            if let h = s.horizontal { parts.append("↔ \(Int(h.rounded())) pt") }
            if let v = s.vertical   { parts.append("↕ \(Int(v.rounded())) pt") }
            return parts.joined(separator: " · ")
        }
    }

    private func chainList(_ chain: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(chain.dropFirst().enumerated()), id: \.offset) { idx, name in
                HStack(spacing: 4) {
                    Text(String(repeating: " ", count: idx * 2) + "└ ")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 2)
    }
}
