import SwiftUI
import VolyModels

struct HierarchyBrowser: View {
    @Bindable var session: InspectorSession
    @Bindable var measurement: MeasurementPane
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText)
                .padding(.horizontal, VolyTheme.gutter)
                .padding(.vertical, 8)
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
                            Section(header: Text(sceneTitle(scene))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(VolyTheme.dim)) {
                                ForEach(scene.windowsInline) { window in
                                    NodeRow(node: window, searchText: searchText, session: session, measurement: measurement)
                                }
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 22)
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
                VolyEmptyState(
                    symbol: "rectangle.3.group",
                    title: "Loading views…",
                    message: "Waiting for the app's view tree."
                )
            }
        }
        .focusable()
        .onKeyPress(.escape) {
            measurement.pinnedID = nil
            return .handled
        }
    }

    /// `UIWindowSceneSessionRoleApplication` → "Application scene".
    private func sceneTitle(_ scene: SceneNode) -> String {
        if let title = scene.title, !title.isEmpty { return title }
        let role = scene.role.replacingOccurrences(of: "UIWindowSceneSessionRole", with: "")
        return role.isEmpty ? "Scene" : "\(role) scene"
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
        // Drawn by us rather than left to the list: the panel is usually
        // not the key window (the Simulator is), and the selection must
        // stay obvious then.
        let highlight = RoundedRectangle(cornerRadius: 5)
            .fill(session.state.selectedViewID == node.id ? VolyTheme.selection.opacity(0.26) : .clear)
            .padding(.horizontal, 6)
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
            .listRowBackground(highlight)
        } else {
            rowLabel
                .tag(node.id)
                .id(node.id)
                .listRowBackground(highlight)
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
            .simultaneousGesture(
                TapGesture().modifiers(.option).onEnded {
                    measurement.togglePin(node.id)
                }
            )
    }

    private func filtered(_ nodes: [ViewNode]) -> [ViewNode] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nodes }
        return nodes.filter { matches($0, q: q) }
    }

    private func matches(_ node: ViewNode, q: String) -> Bool {
        if node.className.lowercased().contains(q) { return true }
        if node.accessibilityIdentifier?.lowercased().contains(q) ?? false { return true }
        if node.label?.lowercased().contains(q) ?? false { return true }
        return node.childrenInline?.contains(where: { matches($0, q: q) }) ?? false
    }
}

private struct NodeLabel: View {
    let node: ViewNode
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10.5))
                .foregroundStyle(VolyTheme.dim)
                .frame(width: 14)
            Text(node.className)
                .font(VolyTheme.code())
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(node.isHidden ? 0.5 : 1)
            if let aid = node.accessibilityIdentifier, !aid.isEmpty {
                Text("#\(aid)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VolyTheme.dim)
                    .lineLimit(1)
            }
            if let label = node.label, !label.isEmpty {
                Text("“\(label)”")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VolyTheme.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(VolyTheme.measurement)
            }
            if node.isHidden {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(VolyTheme.dim)
            }
        }
    }

    private var iconName: String {
        switch node.className {
        case "UIWindow": return "rectangle.on.rectangle"
        case "UILabel", "Text", "TextField": return "textformat"
        case "UIImageView", "Image": return "photo"
        case "UIButton", "Button": return "button.horizontal"
        case "UIStackView", "Row", "Column": return "rectangle.stack"
        case "UIScrollView", "UITableView", "UICollectionView", "LazyColumn", "LazyRow", "LazyGrid":
            return "rectangle.grid.3x2"
        default: return "square.dashed"
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(VolyTheme.dim)
            TextField("", text: $text,
                      prompt: Text("Filter by class, accessibility id or text").foregroundStyle(VolyTheme.faint))
                .textFieldStyle(.plain)
                .font(VolyTheme.body)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(VolyTheme.dim)
                    .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(VolyTheme.field, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(VolyTheme.hairline, lineWidth: 1))
    }
}
