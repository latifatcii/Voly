import SwiftUI
import VolyModels

/// Shows the selected node's class name with a chevron that expands an
/// indented inheritance chain below. No-op if classInheritance is nil (older
/// agent payload).
struct DetailHeader: View {
    let node: ViewNode
    @Bindable var pane: InspectorPane

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
            if node.classInheritance != nil,
               let chain = node.classInheritance, chain.count > 1 {
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
        }
    }

    private func chainList(_ chain: [String]) -> some View {
        // chain[0] is the concrete class, already shown in the header.
        // Show [1...] indented one step each.
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
