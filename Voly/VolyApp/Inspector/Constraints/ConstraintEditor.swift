import SwiftUI
import VolyModels
import VolyProtocol

struct ConstraintEditor: View {
    @Bindable var session: InspectorSession

    var body: some View {
        ScrollView {
            if session.state.constraints.isEmpty {
                Text("No constraints affect this view.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.state.constraints) { c in
                        ConstraintRow(constraint: c) { change in
                            guard let anchor = session.state.selectedViewID else { return }
                            let request = SetConstraintRequest(
                                constraintID: c.id,
                                anchorObjectID: anchor,
                                change: change
                            )
                            Task { await session.setConstraint(request) }
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct ConstraintRow: View {
    let constraint: ConstraintNode
    let onChange: (ConstraintChange) -> Void

    @State private var constantText = ""
    @State private var priority: Float
    @State private var active: Bool

    init(constraint: ConstraintNode, onChange: @escaping (ConstraintChange) -> Void) {
        self.constraint = constraint
        self.onChange = onChange
        _priority = State(initialValue: constraint.priority)
        _active = State(initialValue: constraint.isActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(constraint.summary)
                .font(.caption)
                .fontDesign(.monospaced)
                .lineLimit(2)
                .foregroundStyle(.primary)
            HStack {
                Text("constant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { constantText.isEmpty ? String(format: "%.2f", constraint.constant) : constantText },
                    set: { constantText = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onSubmit {
                    if let c = Double(constantText) { onChange(ConstraintChange(constant: c)) }
                }
                Text("priority")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $priority, in: 1...1000) { editing in
                    if !editing { onChange(ConstraintChange(priority: priority)) }
                }
                .frame(width: 120)
                Text("\(Int(priority))").font(.caption2).frame(width: 40)
                Toggle("active", isOn: $active)
                    .toggleStyle(.checkbox)
                    .onChange(of: active) { _, newValue in
                        onChange(ConstraintChange(isActive: newValue))
                    }
                Spacer()
            }
            if let identifier = constraint.identifier {
                Text("id: \(identifier)").font(.caption2).foregroundStyle(.tertiary)
            }
            if constraint.isSystemGenerated {
                Text("system-generated").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
