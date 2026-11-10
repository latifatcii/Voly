import SwiftUI
import VolyModels
import VolyCodables
import VolyProtocol

struct PropertyPanel: View {
    @Bindable var session: InspectorSession
    @State private var viewExpanded = true
    @State private var layerExpanded = true
    @State private var customExpanded = true

    var body: some View {
        ScrollView {
            if let bag = session.state.propertyBag {
                VStack(alignment: .leading, spacing: 14) {
                    section("View", isExpanded: $viewExpanded) {
                        ForEach(bag.view.keys.sorted(), id: \.self) { key in
                            if let value = bag.view[key] {
                                PropertyRow(name: key, value: value, readOnly: false) { newValue in
                                    set(key, to: newValue, scope: .view, on: bag.objectID)
                                }
                            }
                        }
                    }
                    section("Layer", isExpanded: $layerExpanded) {
                        ForEach(bag.layer.keys.sorted(), id: \.self) { key in
                            if let value = bag.layer[key] {
                                PropertyRow(name: key, value: value, readOnly: false) { newValue in
                                    set(key, to: newValue, scope: .layer, on: bag.objectID)
                                }
                            }
                        }
                    }
                    if !bag.custom.isEmpty {
                        section("Custom", isExpanded: $customExpanded) {
                            ForEach(bag.custom) { descriptor in
                                PropertyRow(
                                    name: descriptor.name,
                                    value: descriptor.currentValue,
                                    readOnly: descriptor.isReadOnly
                                ) { newValue in
                                    set(descriptor.name, to: newValue, scope: .custom, on: bag.objectID)
                                }
                            }
                        }
                    }
                }
                .padding(VolyTheme.gutter)
                // Rows keep what is being typed or picked; that must never
                // carry over to the next view that gets selected.
                .id(bag.objectID)
            } else {
                EmptyView()
            }
        }
    }

    private func set(_ name: String, to value: PropValue, scope: SetPropertyRequest.Scope, on objectID: ObjectID) {
        Task {
            await session.setProperty(SetPropertyRequest(
                objectID: objectID, scope: scope,
                change: PropertyChange(property: name, value: value)))
        }
    }

    /// A collapsible card of property rows.
    private func section<Rows: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VolySection(title) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .foregroundStyle(VolyTheme.dim)
                    .frame(width: 18, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded.wrappedValue ? "Collapse" : "Expand")
        } content: {
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 7) {
                    rows()
                }
                .volyCard()
            }
        }
    }
}

struct PropertyRow: View {
    let name: String
    let value: PropValue
    let readOnly: Bool
    let onChange: (PropValue) -> Void

    var body: some View {
        VolyRow(label: PropertyNameFormatter.humanize(name), labelWidth: 132) {
            editor
        }
        .opacity(readOnly ? 0.75 : 1)
    }

    @ViewBuilder
    private var editor: some View {
        switch value {
        case .bool(let v):
            Toggle("", isOn: Binding(get: { v }, set: { onChange(.bool($0)) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(readOnly)
        case .int(let v):
            HStack(spacing: 6) {
                IntField(value: v, readOnly: readOnly) { onChange(.int($0)) }
                if let label = PropertyValueFormatter.label(forProperty: name, intValue: v) {
                    Text(label)
                        .font(VolyTheme.small)
                        .foregroundStyle(VolyTheme.dim)
                }
            }
        case .double(let v):
            DoubleField(value: v, readOnly: readOnly) { onChange(.double($0)) }
        case .string(let v):
            StringField(value: v, readOnly: readOnly) { onChange(.string($0)) }
        case .color(let c):
            ColorPickerField(color: c, readOnly: readOnly) { onChange(.color($0)) }
        case .size(let s):
            SizeField(value: s, readOnly: readOnly) { onChange(.size($0)) }
        case .null:
            Text("nil").foregroundStyle(VolyTheme.faint).font(VolyTheme.code())
        case .url(let u):
            Text(u.absoluteString).foregroundStyle(VolyTheme.dim).font(VolyTheme.code()).textSelection(.enabled)
        case .rect(let r):
            Text("x \(fmt(r.x))  y \(fmt(r.y))  w \(fmt(r.width))  h \(fmt(r.height))")
                .foregroundStyle(VolyTheme.dim).font(VolyTheme.code()).textSelection(.enabled)
        case .point(let p):
            Text("x \(fmt(p.x))  y \(fmt(p.y))").foregroundStyle(VolyTheme.dim).font(VolyTheme.code()).textSelection(.enabled)
        case .arrayOf, .dictOf:
            Text("Not editable here").foregroundStyle(VolyTheme.faint).font(VolyTheme.small)
        }
    }

    private func fmt(_ d: Double) -> String {
        String(format: "%.1f", d)
    }
}

/// Text that is sent as it is typed. While the field has focus it shows what
/// was typed, not what the app last reported: a reply to an earlier
/// keystroke would otherwise overwrite the characters typed since.
private struct StringField: View {
    let value: String
    let readOnly: Bool
    let onChange: (String) -> Void
    @State private var draft: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: Binding(
            get: { draft ?? value },
            set: { newValue in
                // Only an edit is a change; the field also writes back the
                // text it already shows, e.g. when it gains or loses focus.
                guard newValue != (draft ?? value) else { return }
                draft = newValue
                onChange(newValue)
            }
        ))
        .volyField()
        .focused($isFocused)
        .disabled(readOnly)
        .onChange(of: isFocused) { _, focused in
            if !focused { draft = nil }
        }
    }
}

private struct IntField: View {
    let value: Int64
    let readOnly: Bool
    let onCommit: (Int64) -> Void
    @State private var text = ""
    var body: some View {
        TextField("", text: Binding(get: { text.isEmpty ? "\(value)" : text }, set: { text = $0 }))
            .volyField()
            .frame(width: 100)
            .onSubmit { if let v = Int64(text) { onCommit(v) } }
            .disabled(readOnly)
    }
}

private struct DoubleField: View {
    let value: Double
    let readOnly: Bool
    let onCommit: (Double) -> Void
    @State private var text = ""
    var body: some View {
        TextField("", text: Binding(get: { text.isEmpty ? String(format: "%.3f", value) : text }, set: { text = $0 }))
            .volyField()
            .frame(width: 100)
            .onSubmit { if let v = Double(text) { onCommit(v) } }
            .disabled(readOnly)
    }
}

private struct SizeField: View {
    let value: CGSizeCodable
    let readOnly: Bool
    let onCommit: (CGSizeCodable) -> Void
    var body: some View {
        HStack(spacing: 5) {
            Text("w").font(VolyTheme.code()).foregroundStyle(VolyTheme.dim)
            DoubleField(value: value.width, readOnly: readOnly) { w in
                onCommit(CGSizeCodable(width: w, height: value.height))
            }
            Text("h").font(VolyTheme.code()).foregroundStyle(VolyTheme.dim)
            DoubleField(value: value.height, readOnly: readOnly) { h in
                onCommit(CGSizeCodable(width: value.width, height: h))
            }
        }
    }
}

private struct ColorPickerField: View {
    let color: CGColorCodable
    let readOnly: Bool
    let onCommit: (CGColorCodable) -> Void
    @State private var picked: Color
    init(color: CGColorCodable, readOnly: Bool, onCommit: @escaping (CGColorCodable) -> Void) {
        self.color = color
        self.readOnly = readOnly
        self.onCommit = onCommit
        _picked = State(initialValue: Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
    }
    var body: some View {
        HStack {
            // Only a color picked in the panel is a change. Showing a color
            // the app reported (another view was selected, the value changed
            // in the app) goes through `picked` too and must not be sent
            // back: that would turn an inherited tint or a dynamic color into
            // a fixed one, and recolor all of an attributed text.
            ColorPicker("", selection: Binding(get: { picked }, set: { pick($0) }), supportsOpacity: true)
                .labelsHidden()
                .disabled(readOnly)
            Text(color.hex).font(VolyTheme.code()).foregroundStyle(VolyTheme.dim).textSelection(.enabled)
        }
        .onAppear {
            // Voly's inspector is an NSPanel at .floating level. The system
            // NSColorPanel defaults to .normal and opens hidden behind us.
            // Raise it above so clicking the color swatch actually reveals
            // the picker.
            NSColorPanel.shared.level = .popUpMenu
            NSColorPanel.shared.hidesOnDeactivate = false
        }
        .onChange(of: color) { _, newValue in
            picked = Color(red: newValue.red, green: newValue.green,
                           blue: newValue.blue, opacity: newValue.alpha)
        }
    }

    private func pick(_ newValue: Color) {
        picked = newValue
        let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? NSColor(newValue)
        let chosen = CGColorCodable(
            red: Double(ns.redComponent), green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent)
        )
        // The panel echoes the color it was just shown; that is not a pick.
        guard Self.differ(chosen, color) else { return }
        onCommit(chosen)
    }

    /// Whether two colors are further apart than 8-bit rounding.
    private static func differ(_ a: CGColorCodable, _ b: CGColorCodable) -> Bool {
        let step = 0.5 / 255
        return abs(a.red - b.red) > step || abs(a.green - b.green) > step
            || abs(a.blue - b.blue) > step || abs(a.alpha - b.alpha) > step
    }
}
