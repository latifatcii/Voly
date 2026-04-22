import SwiftUI
import VolyModels
import VolyProtocol

struct ConstraintCard: View {
    let constraint: ConstraintNode
    let anchorObjectID: ObjectID
    let onChange: (SetConstraintRequest) -> Void

    @State private var isEditing = false
    @State private var constantText: String = ""
    @State private var priorityText: String = ""
    @State private var active: Bool

    init(
        constraint: ConstraintNode,
        anchorObjectID: ObjectID,
        onChange: @escaping (SetConstraintRequest) -> Void
    ) {
        self.constraint = constraint
        self.anchorObjectID = anchorObjectID
        self.onChange = onChange
        _active = State(initialValue: constraint.isActive)
        _constantText = State(initialValue: Self.format(constraint.constant))
        _priorityText = State(initialValue: Self.format(Double(constraint.priority)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isEditing { editor }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .opacity(constraint.isActive ? 1.0 : 0.6)
        .onChange(of: constraint.constant) { _, newValue in
            if !isEditing { constantText = Self.format(newValue) }
        }
        .onChange(of: constraint.priority) { _, newValue in
            if !isEditing { priorityText = Self.format(Double(newValue)) }
        }
        .onChange(of: constraint.isActive) { _, newValue in
            // Active toggle syncs externally even mid-edit; server-acked.
            active = newValue
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(constraint.summary)
                .font(.system(size: 12, design: .monospaced))
                .strikethrough(!constraint.isActive)
                .lineLimit(2)
            Spacer(minLength: 0)
            if constraint.isSystemGenerated {
                Text("system")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15),
                                in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Button(isEditing ? "Done" : "Edit") {
                if isEditing { commitAll() }
                isEditing.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledField("Constant", text: $constantText, onCommit: commitConstant)
            labeledField("Priority", text: $priorityText, onCommit: commitPriority)
            HStack {
                Text("Multiplier")
                    .font(.caption).frame(width: 80, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(Self.format(constraint.multiplier))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Multiplier is read-only; Auto Layout can't change it after creation.")
                Spacer()
            }
            Toggle("Active", isOn: $active)
                .toggleStyle(.checkbox)
                .onChange(of: active) { _, newValue in
                    send(.init(isActive: newValue))
                }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, onCommit: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .font(.caption).frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
                .onSubmit(onCommit)
            Spacer()
        }
    }

    private func commitAll() {
        commitConstant()
        commitPriority()
    }

    private func commitConstant() {
        guard let v = Double(constantText) else { return }
        send(.init(constant: v))
    }

    private func commitPriority() {
        guard let v = Float(priorityText), (1...1000).contains(v) else { return }
        send(.init(priority: v))
    }

    private func send(_ change: ConstraintChange) {
        onChange(.init(
            constraintID: constraint.id,
            anchorObjectID: anchorObjectID,
            change: change
        ))
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 3
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
