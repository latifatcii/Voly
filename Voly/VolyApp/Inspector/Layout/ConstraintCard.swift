import SwiftUI
import VolyHost
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
        .volyCard(padding: 9)
        .opacity(constraint.isActive ? 1.0 : 0.55)
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
        let presentation = ConstraintPresentation(constraint)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.label)
                .foregroundStyle(VolyTheme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: VolyTheme.labelWidth, alignment: .trailing)
            Text(presentation.value)
                .font(VolyTheme.code())
                .strikethrough(!constraint.isActive)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(constraint.summary)
            Spacer(minLength: 0)
            if constraint.priority < 1000 {
                VolyChip(text: "@\(Int(constraint.priority))")
                    .help("Priority \(Int(constraint.priority))")
            }
            if constraint.isSystemGenerated {
                VolyChip(text: "system")
            }
            Button(isEditing ? "Done" : "Edit") {
                if isEditing { commitAll() }
                isEditing.toggle()
            }
            .buttonStyle(VolyTextButtonStyle())
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            VolyRow(label: "Constant") {
                TextField("", text: $constantText)
                    .volyField()
                    .frame(maxWidth: 150)
                    .onSubmit(commitConstant)
            }
            VolyRow(label: "Priority") {
                TextField("", text: $priorityText)
                    .volyField()
                    .frame(maxWidth: 150)
                    .onSubmit(commitPriority)
            }
            VolyRow(label: "Multiplier") {
                Text(Self.format(constraint.multiplier))
                    .font(VolyTheme.code())
                    .foregroundStyle(VolyTheme.faint)
                    .padding(.horizontal, 7)
                    .help("Multiplier is read-only; Auto Layout can't change it after creation.")
            }
            VolyRow(label: "") {
                Toggle("Active", isOn: $active)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .onChange(of: active) { _, newValue in
                        send(.init(isActive: newValue))
                    }
            }
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
        // Code-style numbers: a decimal point regardless of the Mac's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 3
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
