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
                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("View", isExpanded: $viewExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(bag.view.keys.sorted(), id: \.self) { key in
                                if let value = bag.view[key] {
                                    PropertyRow(
                                        name: key,
                                        value: value,
                                        readOnly: false,
                                        onChange: { newValue in
                                            Task {
                                                await session.setProperty(SetPropertyRequest(
                                                    objectID: bag.objectID, scope: .view,
                                                    change: PropertyChange(property: key, value: newValue)))
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    DisclosureGroup("Layer", isExpanded: $layerExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(bag.layer.keys.sorted(), id: \.self) { key in
                                if let value = bag.layer[key] {
                                    PropertyRow(
                                        name: key,
                                        value: value,
                                        readOnly: false,
                                        onChange: { newValue in
                                            Task {
                                                await session.setProperty(SetPropertyRequest(
                                                    objectID: bag.objectID, scope: .layer,
                                                    change: PropertyChange(property: key, value: newValue)))
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    if !bag.custom.isEmpty {
                        DisclosureGroup("Custom", isExpanded: $customExpanded) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(bag.custom) { descriptor in
                                    PropertyRow(
                                        name: descriptor.name,
                                        value: descriptor.currentValue,
                                        readOnly: descriptor.isReadOnly,
                                        onChange: { newValue in
                                            Task {
                                                await session.setProperty(SetPropertyRequest(
                                                    objectID: bag.objectID, scope: .custom,
                                                    change: PropertyChange(property: descriptor.name, value: newValue)))
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                EmptyView()
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
        HStack(alignment: .top) {
            Text(PropertyNameFormatter.humanize(name))
                .font(.caption)
                .frame(width: 150, alignment: .leading)
                .foregroundStyle(.primary)
            editor.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch value {
        case .bool(let v):
            Toggle("", isOn: Binding(get: { v }, set: { onChange(.bool($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(readOnly)
        case .int(let v):
            HStack(spacing: 6) {
                IntField(value: v, readOnly: readOnly) { onChange(.int($0)) }
                if let label = PropertyValueFormatter.label(forProperty: name, intValue: v) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .double(let v):
            DoubleField(value: v, readOnly: readOnly) { onChange(.double($0)) }
        case .string(let v):
            TextField("", text: Binding(get: { v }, set: { onChange(.string($0)) }))
                .textFieldStyle(.roundedBorder)
                .disabled(readOnly)
        case .color(let c):
            ColorPickerField(color: c, readOnly: readOnly) { onChange(.color($0)) }
        case .size(let s):
            SizeField(value: s, readOnly: readOnly) { onChange(.size($0)) }
        case .null:
            Text("(null)").foregroundStyle(.tertiary).font(.caption)
        case .url(let u):
            Text(u.absoluteString).foregroundStyle(.secondary).font(.caption)
        case .rect(let r):
            Text("x:\(fmt(r.x)) y:\(fmt(r.y)) w:\(fmt(r.width)) h:\(fmt(r.height))")
                .foregroundStyle(.secondary).font(.caption).fontDesign(.monospaced)
        case .point(let p):
            Text("x:\(fmt(p.x)) y:\(fmt(p.y))").foregroundStyle(.secondary).font(.caption).fontDesign(.monospaced)
        case .arrayOf, .dictOf:
            Text("(complex value)").foregroundStyle(.tertiary).font(.caption)
        }
    }

    private func fmt(_ d: Double) -> String {
        String(format: "%.1f", d)
    }
}

private struct IntField: View {
    let value: Int64
    let readOnly: Bool
    let onCommit: (Int64) -> Void
    @State private var text = ""
    var body: some View {
        TextField("", text: Binding(get: { text.isEmpty ? "\(value)" : text }, set: { text = $0 }))
            .textFieldStyle(.roundedBorder)
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
            .textFieldStyle(.roundedBorder)
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
        HStack(spacing: 4) {
            Text("w")
            DoubleField(value: value.width, readOnly: readOnly) { w in
                onCommit(CGSizeCodable(width: w, height: value.height))
            }
            Text("h")
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
            ColorPicker("", selection: $picked, supportsOpacity: true)
                .labelsHidden()
                .disabled(readOnly)
            Text(color.hex).font(.caption2).foregroundStyle(.secondary).fontDesign(.monospaced)
        }
        .onAppear {
            // Voly's inspector is an NSPanel at .floating level. The system
            // NSColorPanel defaults to .normal and opens hidden behind us.
            // Raise it above so clicking the color swatch actually reveals
            // the picker.
            NSColorPanel.shared.level = .popUpMenu
            NSColorPanel.shared.hidesOnDeactivate = false
        }
        .onChange(of: picked) { _, newValue in
            let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? NSColor(newValue)
            onCommit(CGColorCodable(red: Double(ns.redComponent),
                                    green: Double(ns.greenComponent),
                                    blue: Double(ns.blueComponent),
                                    alpha: Double(ns.alphaComponent)))
        }
        .onChange(of: colorIdentity) { _, _ in
            // Re-seed local state if the color is updated externally (e.g. the
            // server clamped / replaced the value after we committed).
            picked = Color(red: color.red, green: color.green,
                           blue: color.blue, opacity: color.alpha)
        }
    }

    /// Tuple used as the observation key so SwiftUI detects external color
    /// changes on the incoming `color` value.
    private var colorIdentity: String {
        "\(color.red),\(color.green),\(color.blue),\(color.alpha)"
    }
}
