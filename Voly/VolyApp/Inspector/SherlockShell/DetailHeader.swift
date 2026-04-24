import SwiftUI
import VolyModels

/// Shows the selected node's class name with a chevron that expands an
/// indented inheritance chain below. Also shows the measurement badge on the
/// trailing edge when a hover or pinned second view is active.
struct DetailHeader: View {
    let node: ViewNode
    @Bindable var pane: InspectorPane
    @Bindable var measurement: MeasurementPane
    let lastSummary: MeasurementSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
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
