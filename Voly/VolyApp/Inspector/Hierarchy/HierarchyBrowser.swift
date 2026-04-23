import SwiftUI
import VolyModels

struct HierarchyBrowser: View {
    @Bindable var session: InspectorSession
    @Bindable var measurement: MeasurementPane
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            if let snapshot = session.state.hierarchy {
                ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { session.state.selectedViewID },
                        set: { newValue in
                            if let id = newValue {
                                Task { await session.select(id) }
                            }
                        }
                    )) {
                        ForEach(snapshot.scenes) { scene in
                            Section(header: Text(scene.title ?? scene.role).font(.caption).bold()) {
                                ForEach(scene.windowsInline) { window in
                                    NodeRow(node: window, searchText: searchText, session: session, measurement: measurement)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: session.state.selectedViewID) { _, newID in
                        revealSelection(id: newID, proxy: proxy)
                    }
                    // When the hierarchy snapshot refreshes (e.g. after a pick
                    // whose view wasn't yet in the cached tree) re-run reveal
                    // so ancestors expand and we scroll to the new row.
                    .onChange(of: session.state.hierarchy?.issuedAt) { _, _ in
                        revealSelection(id: session.state.selectedViewID, proxy: proxy)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Hierarchy",
                    systemImage: "rectangle.3.group",
                    description: Text("Connect to a running VolyAgent-enabled app.")
                )
            }
        }
        .focusable()
        .onKeyPress(.escape) {
            measurement.pinnedID = nil
            return .handled
        }
    }

    private func revealSelection(id: ObjectID?, proxy: ScrollViewProxy) {
        guard let id else { return }
        session.state.expandAncestors(of: id)
        // Deep DisclosureGroup chains need a few render ticks to materialize
        // the rows so scrollTo can target them. 120ms is comfortably more than
        // a single runloop pass yet invisible in practice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

private struct NodeRow: View {
    let node: ViewNode
    let searchText: String
    @Bindable var session: InspectorSession
    @Bindable var measurement: MeasurementPane

    var body: some View {
        // Read the Set here (not only inside the Binding closure) so SwiftUI
        // registers NodeRow as an observer; without this, mutating
        // expandedNodeIDs programmatically doesn't re-render the DisclosureGroup.
        let isExpanded = session.state.expandedNodeIDs.contains(node.id)
        let hasChildren = !node.childIDs.isEmpty
        if hasChildren {
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    if newValue {
                        session.state.expandedNodeIDs.insert(node.id)
                        if node.childrenInline == nil || (node.childrenInline?.isEmpty == true && !node.childIDs.isEmpty) {
                            Task { await session.loadSubtree(for: node.id, depth: 4) }
                        }
                    } else {
                        session.state.expandedNodeIDs.remove(node.id)
                    }
                }
            )) {
                if let children = node.childrenInline {
                    ForEach(filtered(children)) { child in
                        NodeRow(node: child, searchText: searchText, session: session, measurement: measurement)
                    }
                } else {
                    Label("Loading…", systemImage: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } label: {
                rowLabel
            }
            .tag(node.id)
            .id(node.id)
        } else {
            rowLabel
                .tag(node.id)
                .id(node.id)
        }
    }

    @ViewBuilder
    private var rowLabel: some View {
        NodeLabel(node: node, isPinned: measurement.pinnedID == node.id)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    measurement.hoverID = node.id
                } else if measurement.hoverID == node.id {
                    measurement.hoverID = nil
                }
            }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) {
                    measurement.togglePin(node.id)
                }
            }
    }

    private func filtered(_ nodes: [ViewNode]) -> [ViewNode] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nodes }
        return nodes.filter { node in
            node.className.lowercased().contains(q) ||
                (node.accessibilityIdentifier?.lowercased().contains(q) ?? false) ||
                node.childrenInline?.contains(where: { matches($0, q: q) }) ?? false
        }
    }

    private func matches(_ node: ViewNode, q: String) -> Bool {
        if node.className.lowercased().contains(q) { return true }
        if node.accessibilityIdentifier?.lowercased().contains(q) ?? false { return true }
        return node.childrenInline?.contains(where: { matches($0, q: q) }) ?? false
    }
}

private struct NodeLabel: View {
    let node: ViewNode
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(node.className)
                .fontDesign(.monospaced)
                .font(.caption)
            if let aid = node.accessibilityIdentifier, !aid.isEmpty {
                Text("#\(aid)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if node.isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var iconName: String {
        switch node.className {
        case "UIWindow": return "rectangle.on.rectangle"
        case "UILabel": return "textformat"
        case "UIImageView": return "photo"
        case "UIButton": return "button.horizontal"
        case "UIStackView": return "rectangle.stack"
        case "UIScrollView", "UITableView", "UICollectionView": return "rectangle.grid.3x2"
        default: return "square.dashed"
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Class or accessibility id", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
