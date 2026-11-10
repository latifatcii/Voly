import SwiftUI

/// Voly's inspector look: a compact graphite panel that sits beside the
/// Simulator without competing with it. The panel is always dark, so it
/// reads the same next to a light or dark app and against any wallpaper.
///
/// Two colors carry meaning and nothing else is tinted: blue is *selection*
/// (it matches the highlight Voly draws on the device), orange is
/// *measurement*.
enum VolyTheme {
    static let panel = Color(red: 0.090, green: 0.094, blue: 0.110)        // #17181C
    static let chrome = Color(red: 0.059, green: 0.063, blue: 0.075)       // #0F1013
    static let card = Color(red: 0.118, green: 0.125, blue: 0.149)         // #1E2026
    static let hairline = Color(red: 0.176, green: 0.188, blue: 0.220)     // #2D3038
    static let field = Color(red: 0.071, green: 0.075, blue: 0.090)        // #121317
    static let hover = Color.white.opacity(0.07)

    static let text = Color(red: 0.914, green: 0.918, blue: 0.925)         // #E9EAEC
    static let dim = Color(red: 0.553, green: 0.565, blue: 0.600)          // #8D9099
    static let faint = Color(red: 0.380, green: 0.392, blue: 0.431)        // #61646E

    static let selection = Color(red: 0.298, green: 0.553, blue: 1.0)      // #4C8DFF
    static let measurement = Color.orange
    static let ok = Color(red: 0.204, green: 0.780, blue: 0.349)           // #34C759
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.039)        // #FF9F0A
    static let danger = Color(red: 1.0, green: 0.412, blue: 0.380)         // #FF6961

    static let cardRadius: CGFloat = 8
    static let gutter: CGFloat = 10
    /// Width of the right-aligned label column inside cards.
    static let labelWidth: CGFloat = 104

    static let body = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let title = Font.system(size: 13, weight: .semibold)
    /// Identifiers and numbers: class names, selectors, coordinates.
    static func code(_ size: CGFloat = 11.5) -> Font { .system(size: size, design: .monospaced) }
}

extension View {
    /// A bordered surface one step above the panel.
    func volyCard(padding: CGFloat = 10) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VolyTheme.card, in: RoundedRectangle(cornerRadius: VolyTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: VolyTheme.cardRadius)
                    .strokeBorder(VolyTheme.hairline, lineWidth: 1)
            )
    }

    /// Recessed input well for plain text fields.
    func volyField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(VolyTheme.code())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(VolyTheme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(VolyTheme.hairline, lineWidth: 1))
    }
}

/// A titled group of cards. The title names what the cards are; an optional
/// accessory sits at its trailing edge.
struct VolySection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(VolyTheme.dim)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 2)
            content
        }
    }
}

extension VolySection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// One "label: value" line inside a card, label right-aligned so values
/// line up down the card.
struct VolyRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = VolyTheme.labelWidth
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(VolyTheme.body)
                .foregroundStyle(VolyTheme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: labelWidth, alignment: .trailing)
                .help(label)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small quiet tag ("system", "RTL", a type name).
struct VolyChip: View {
    let text: String
    var color: Color = VolyTheme.dim

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Icon button for the header and footer bars: quiet until hovered, tinted
/// when it represents something that is switched on.
struct VolyIconButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        Icon(configuration: configuration, isOn: isOn)
    }

    private struct Icon: View {
        let configuration: Configuration
        let isOn: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? VolyTheme.selection : VolyTheme.dim)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? VolyTheme.selection.opacity(0.16)
                              : (hovering || configuration.isPressed ? VolyTheme.hover : .clear))
                )
                .opacity(isEnabled ? 1 : 0.32)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Text button used inside cards ("Edit", "Done", "Relaunch…").
struct VolyTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(VolyTheme.text.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.09), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// A text field in a recessed well, with its placeholder clearly quieter
/// than typed text.
struct VolyTextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(VolyTheme.faint))
            .volyField()
    }
}

/// What a tab shows when it has nothing to show: what is missing, and the
/// one thing to do about it.
struct VolyEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(VolyTheme.faint)
                .padding(.bottom, 2)
            Text(title)
                .font(VolyTheme.title)
                .foregroundStyle(VolyTheme.text)
            Text(message)
                .font(VolyTheme.body)
                .foregroundStyle(VolyTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(VolyTextButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
