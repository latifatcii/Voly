import SwiftUI
import VolyModels
import VolyCodables

struct PreviewControlPanel: View {
    @Bindable var session: InspectorSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Resize the running iOS app's root container. Changes apply live via the VolyAgent preview host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox("Size") { sizeControls }
                GroupBox("Safe area insets") { safeAreaControls }
                GroupBox("Traits") { traitControls }

                HStack {
                    Button("Apply") { Task { await apply() } }
                        .keyboardShortcut(.return)
                    Button("Reset") { Task { await reset() } }
                    Spacer()
                }

                if let applied = session.state.previewApplied {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Applied: \(Int(applied.actualSize.width)) × \(Int(applied.actualSize.height))")
                            .font(.caption)
                        ForEach(applied.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var sizeControls: some View {
        VStack {
            ParamSlider(label: "Width", value: Binding(
                get: { session.state.previewConfig.size.width },
                set: { session.state.previewConfig.size.width = $0 }),
                range: 280...1366, step: 1
            )
            ParamSlider(label: "Height", value: Binding(
                get: { session.state.previewConfig.size.height },
                set: { session.state.previewConfig.size.height = $0 }),
                range: 480...1366, step: 1
            )
        }
    }

    @ViewBuilder
    private var safeAreaControls: some View {
        VStack {
            ParamSlider(label: "Top", value: Binding(
                get: { session.state.previewConfig.safeAreaInsets.top },
                set: { session.state.previewConfig.safeAreaInsets.top = $0 }),
                range: 0...80, step: 1
            )
            ParamSlider(label: "Bottom", value: Binding(
                get: { session.state.previewConfig.safeAreaInsets.bottom },
                set: { session.state.previewConfig.safeAreaInsets.bottom = $0 }),
                range: 0...80, step: 1
            )
            ParamSlider(label: "Left", value: Binding(
                get: { session.state.previewConfig.safeAreaInsets.left },
                set: { session.state.previewConfig.safeAreaInsets.left = $0 }),
                range: 0...60, step: 1
            )
            ParamSlider(label: "Right", value: Binding(
                get: { session.state.previewConfig.safeAreaInsets.right },
                set: { session.state.previewConfig.safeAreaInsets.right = $0 }),
                range: 0...60, step: 1
            )
        }
    }

    @ViewBuilder
    private var traitControls: some View {
        VStack(alignment: .leading) {
            Picker("Appearance", selection: Binding(
                get: { session.state.previewConfig.userInterfaceStyle },
                set: { session.state.previewConfig.userInterfaceStyle = $0 })
            ) {
                Text("Unspecified").tag(PreviewConfig.UIStyle.unspecified)
                Text("Light").tag(PreviewConfig.UIStyle.light)
                Text("Dark").tag(PreviewConfig.UIStyle.dark)
            }
            Picker("Layout", selection: Binding(
                get: { session.state.previewConfig.layoutDirection },
                set: { session.state.previewConfig.layoutDirection = $0 })
            ) {
                Text("LTR").tag(PreviewConfig.LayoutDirection.ltr)
                Text("RTL").tag(PreviewConfig.LayoutDirection.rtl)
            }
            Picker("Content size", selection: Binding(
                get: { session.state.previewConfig.contentSizeCategory },
                set: { session.state.previewConfig.contentSizeCategory = $0 })
            ) {
                ForEach(allContentSizes, id: \.self) { c in
                    Text(String(describing: c).uppercased()).tag(c)
                }
            }
        }
    }

    private var allContentSizes: [PreviewConfig.ContentSize] {
        [.unspecified, .xs, .s, .m, .l, .xl, .xxl, .xxxl, .ax1, .ax2, .ax3, .ax4, .ax5]
    }

    private func apply() async {
        let applied = await session.applyPreview(session.state.previewConfig)
        session.state.previewApplied = applied
    }

    private func reset() async {
        await session.clearPreview()
        session.state.previewConfig = PreviewConfig(size: .init(width: 390, height: 844))
        session.state.previewApplied = nil
    }
}

private struct ParamSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text("\(Int(value))").font(.caption).frame(width: 40)
        }
    }
}
