import SwiftUI
import VolyCodables
import VolyModels
import VolyProtocol

struct LayoutTab: View {
    @Bindable var session: InspectorSession

    var body: some View {
        ScrollView {
            if let node = selectedNode() {
                VStack(alignment: .leading, spacing: 14) {
                    viewSection(node)
                    constraintsSection(node)
                }
                .padding(VolyTheme.gutter)
            } else {
                EmptyView()
            }
        }
    }

    private func selectedNode() -> ViewNode? {
        guard let id = session.state.selectedViewID else { return nil }
        return session.state.findNode(id: id)
    }

    private func rect(from codable: CGRectCodable) -> CGRect {
        CGRect(x: codable.x, y: codable.y, width: codable.width, height: codable.height)
    }

    private func parentFrame(of node: ViewNode) -> CGRect {
        guard let snapshot = session.state.hierarchy else { return .zero }
        for scene in snapshot.scenes {
            for window in scene.windowsInline {
                if containsNode(id: node.id, in: window) {
                    return rect(from: window.frame)
                }
            }
        }
        return .zero
    }

    private func containsNode(id: ObjectID, in node: ViewNode) -> Bool {
        if node.id == id { return true }
        for child in node.childrenInline ?? [] {
            if containsNode(id: id, in: child) { return true }
        }
        return false
    }

    private func viewSection(_ node: ViewNode) -> some View {
        let frame = rect(from: node.frame)
        let bounds = rect(from: node.bounds)
        return VolySection("View") {
            VStack(alignment: .leading, spacing: 10) {
                geometryRow("Frame", child: frame, parent: parentFrame(of: node), rect: frame)
                VolyTheme.hairline.frame(height: 1)
                geometryRow("Bounds", child: bounds, parent: bounds, rect: bounds)
            }
            .volyCard()
        }
    }

    /// Label, a to-scale swatch of the rect inside its container, and the
    /// four numbers in two columns.
    private func geometryRow(_ label: String, child: CGRect, parent: CGRect, rect: CGRect) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(VolyTheme.dim)
                .frame(width: 52, alignment: .trailing)
            FrameSwatch(child: child, parent: parent, cellSize: 52)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    number("x", rect.minX)
                    number("y", rect.minY)
                }
                GridRow {
                    number("w", rect.width)
                    number("h", rect.height)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func number(_ label: String, _ value: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(VolyTheme.code())
                .foregroundStyle(VolyTheme.dim)
            Text(Self.format(Double(value)))
                .font(VolyTheme.code())
                .textSelection(.enabled)
        }
        .frame(minWidth: 74, alignment: .leading)
    }

    @ViewBuilder
    private func constraintsSection(_ node: ViewNode) -> some View {
        if !session.state.constraints.isEmpty {
            VolySection("Constraints") {
                Text("\(session.state.constraints.count)")
                    .font(VolyTheme.code(10.5))
                    .foregroundStyle(VolyTheme.faint)
            } content: {
                ForEach(session.state.constraints) { c in
                    ConstraintCard(
                        constraint: c,
                        anchorObjectID: node.id,
                        onChange: { req in
                            Task { await session.setConstraint(req) }
                        }
                    )
                }
            }
        }
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        // Code-style numbers: a decimal point regardless of the Mac's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 3
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
