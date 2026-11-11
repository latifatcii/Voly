import Foundation
import VolyCodables
import VolyModels

/// Turns a `ScreenDescription` into text an AI agent can read in one go:
/// one line per view, indented by depth, carrying what the view shows and
/// how it is styled.
///
///     UILabel #13 16,118 159×26 "Welcome" font=System Semibold 22 color=#000000 id=greeting
///
/// Two things keep a real screen within what a model can take in at once:
/// chains of same-sized wrapper views are folded onto one line, and when the
/// whole tree is still too long the deepest levels are replaced by a count
/// and the id to ask for them with.
public struct ScreenDescriptionFormatter: Sendable {
    /// Fold chains of plain wrapper views (`A #1 › B #2 › C #3 …`).
    public var collapsesWrappers = true
    /// Upper bound for the tree text, in characters.
    public var characterBudget = 40_000
    /// Longest text shown for one view before it is cut.
    public var maxTextLength = 140

    public init() {}

    public struct Tree: Equatable, Sendable {
        public let text: String
        /// Levels shown when the tree had to be cut to fit; nil when whole.
        public let levelsShown: Int?
    }

    // MARK: - Whole screen

    public func header(for screen: ScreenDescription, simulator: String?, platform: MCPPlatform = .iOS) -> String {
        var first = screen.appName
        if let bundle = screen.bundleIdentifier { first += " (\(bundle))" }
        if let simulator { first += " in \(simulator)" }
        let android = platform == .android
        var second = "Screen \(Self.number(screen.screenSize.width))×\(Self.number(screen.screenSize.height)) \(android ? "dp" : "pt")"
            + " @\(Self.number(screen.scale))x, \(screen.orientation.rawValue), \(screen.appearance) mode"
            + (android ? ", font scale \(screen.contentSizeCategory)." : ", text size \(screen.contentSizeCategory).")
        if let top = screen.topViewController {
            second += android ? " Top screen: \(Self.shortClassName(top))." : " Top view controller: \(Self.shortClassName(top))."
        }
        return first + "\n" + second
    }

    public static let legend = """
        One line per view: Class #id x,y width×height (window points), then what it shows. \
        Lines starting with ~ are accessibility elements inside a view (how SwiftUI content appears). \
        ⚠ marks a likely layout problem. Use a #id with get_view, screenshot or set_property.
        """

    /// The same, in Android's words: frames are dp from the display's
    /// top-left corner, `id=` is the view's `android:id`, and `~` lines are
    /// Jetpack Compose semantics nodes, which have ids like views.
    public static let androidLegend = """
        One line per view: Class #id x,y width×height (dp, from the display's top-left corner), then what it \
        shows; id= is the view's android:id and vc= the activity or fragment it is the root of. \
        Lines starting with ~ are semantics nodes inside a view (how Jetpack Compose content appears); \
        their #id works like a view's, and get_screen with root set to one lists every layout node in it. \
        ⚠ marks a likely layout problem. Use a #id with get_view, screenshot or set_property.
        """

    public static func legend(for platform: MCPPlatform) -> String {
        platform == .android ? androidLegend : legend
    }

    /// The view tree, cut by depth if it would exceed the budget.
    public func tree(for screen: ScreenDescription) -> Tree {
        let whole = render(screen.roots, maxLevels: nil)
        guard whole.count > characterBudget else { return Tree(text: whole, levelsShown: nil) }
        var levels = screen.roots.map(levelCount).max() ?? 1
        while levels > 1 {
            levels -= 1
            let cut = render(screen.roots, maxLevels: levels)
            if cut.count <= characterBudget { return Tree(text: cut, levelsShown: levels) }
        }
        let shallowest = render(screen.roots, maxLevels: 1)
        return Tree(text: String(shallowest.prefix(characterBudget)), levelsShown: 1)
    }

    /// Every flagged view, however deep, so a problem is never lost to the
    /// depth cut.
    public func problems(in screen: ScreenDescription, limit: Int = 25) -> String? {
        var flagged: [ViewDescription] = []
        func collect(_ node: ViewDescription) {
            if !node.flags.isEmpty { flagged.append(node) }
            node.children.forEach(collect)
        }
        screen.roots.forEach(collect)
        guard !flagged.isEmpty else { return nil }
        var lines = flagged.prefix(limit).map { node in
            "- \(node.flags.map(Self.describe).joined(separator: ", ")): \(Self.shortClassName(node.className)) #\(node.id)"
                + (node.text.map { " \(quote($0))" } ?? "")
        }
        if flagged.count > limit { lines.append("- …and \(flagged.count - limit) more") }
        return "Possible problems (\(flagged.count)):\n" + lines.joined(separator: "\n")
    }

    // MARK: - One view

    /// Everything known about one view on one line, without indentation.
    public func line(for node: ViewDescription) -> String {
        var parts = ["\(Self.shortClassName(node.className)) #\(node.id)", Self.frame(node.frame)]
        if let text = node.text { parts.append(quote(text)) }
        if let placeholder = node.placeholder { parts.append("placeholder=\(quote(placeholder))") }
        if let value = node.value { parts.append("value=\(value)") }
        if let font = node.font { parts.append("font=\(font)") }
        if let color = node.textColor { parts.append("color=\(Self.color(color))") }
        if let color = node.backgroundColor { parts.append("bg=\(Self.color(color))") }
        if let color = node.tintColor { parts.append("tint=\(Self.color(color))") }
        if let alignment = node.textAlignment { parts.append("align=\(alignment)") }
        if let lines = node.numberOfLines, lines != 1 { parts.append("lines=\(lines)") }
        if let radius = node.cornerRadius { parts.append("radius=\(Self.number(radius))") }
        if let width = node.borderWidth {
            parts.append("border=\(Self.number(width))" + (node.borderColor.map { " \(Self.color($0))" } ?? ""))
        }
        if let image = node.image { parts.append("image=\(image)") }
        if let stack = node.stack { parts.append("stack(\(stack))") }
        if let scroll = node.scroll { parts.append("scroll(\(scroll))") }
        if let identifier = node.accessibilityIdentifier { parts.append("id=\(identifier)") }
        if let label = node.accessibilityLabel, label != node.text { parts.append("label=\(quote(label))") }
        if let controller = node.viewController { parts.append("vc=\(Self.shortClassName(controller))") }
        if node.alpha < 0.995 { parts.append("alpha=\(Self.number(node.alpha))") }
        if node.isHidden { parts.append("hidden") }
        if !node.state.isEmpty { parts.append("[\(node.state.joined(separator: ", "))]") }
        for flag in node.flags { parts.append("⚠ \(Self.describe(flag))") }
        return parts.joined(separator: " ")
    }

    public func line(for element: AccessibilityElementDescription) -> String {
        var parts = ["~"]
        if let id = element.id { parts.append("#\(id)") }
        if let label = element.label, !label.isEmpty { parts.append(quote(label)) }
        if let value = element.value, !value.isEmpty { parts.append("value=\(quote(value))") }
        if !element.traits.isEmpty { parts.append(element.traits.joined(separator: ",")) }
        parts.append(Self.frame(element.frame))
        if let identifier = element.identifier { parts.append("id=\(identifier)") }
        return parts.joined(separator: " ")
    }

    /// A subtree as indented lines (no header), e.g. a view's subviews.
    public func lines(for nodes: [ViewDescription], maxLevels: Int? = nil) -> String {
        render(nodes, maxLevels: maxLevels)
    }

    // MARK: - Rendering

    private func render(_ roots: [ViewDescription], maxLevels: Int?) -> String {
        var lines: [String] = []
        for root in roots { append(root, level: 0, maxLevels: maxLevels, to: &lines) }
        return lines.joined(separator: "\n")
    }

    private func append(_ node: ViewDescription, level: Int, maxLevels: Int?, to lines: inout [String]) {
        let (chain, last) = wrapperChain(from: node)
        let indent = String(repeating: "  ", count: level)
        let prefix = chain.map { "\(Self.shortClassName($0.className)) #\($0.id) › " }.joined()
        var line = indent + prefix + self.line(for: last)

        let cut = maxLevels.map { level + 1 >= $0 } ?? false
        let hiddenBelow = cut ? last.children.reduce(0) { $0 + viewCount($1) } : 0
        var notes: [String] = []
        if hiddenBelow > 0 { notes.append("+\(hiddenBelow) views inside, get_screen root=\(last.id)") }
        if last.omittedChildren > 0 { notes.append("+\(last.omittedChildren) hidden or deeper subviews not listed") }
        if !notes.isEmpty { line += " (\(notes.joined(separator: "; ")))" }
        lines.append(line)

        for element in last.accessibilityElements ?? [] {
            lines.append(indent + "  " + self.line(for: element))
        }
        guard !cut else { return }
        for child in last.children {
            append(child, level: level + 1, maxLevels: maxLevels, to: &lines)
        }
    }

    /// `node` and the plain wrappers it leads through, ending at the first
    /// view that has something of its own to say.
    private func wrapperChain(from node: ViewDescription) -> (wrappers: [ViewDescription], last: ViewDescription) {
        guard collapsesWrappers else { return ([], node) }
        var wrappers: [ViewDescription] = []
        var current = node
        while isPlainWrapper(current), let child = current.children.first {
            wrappers.append(current)
            current = child
        }
        return (wrappers, current)
    }

    private func isPlainWrapper(_ node: ViewDescription) -> Bool {
        guard node.children.count == 1, node.omittedChildren == 0, let child = node.children.first else { return false }
        let plain = node.text == nil && node.placeholder == nil && node.value == nil && node.image == nil
            && node.accessibilityIdentifier == nil && node.accessibilityLabel == nil && node.viewController == nil
            && node.backgroundColor == nil && node.cornerRadius == nil && node.borderWidth == nil
            && node.stack == nil && node.scroll == nil && node.accessibilityElements == nil
            && node.flags.isEmpty && node.state.isEmpty && !node.isHidden && node.alpha >= 0.995
        guard plain else { return false }
        let a = node.frame, b = child.frame
        return abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// Levels the tree takes when rendered (a folded chain is one level).
    private func levelCount(_ node: ViewDescription) -> Int {
        let last = wrapperChain(from: node).last
        return 1 + (last.children.map(levelCount).max() ?? 0)
    }

    private func viewCount(_ node: ViewDescription) -> Int {
        1 + node.children.reduce(0) { $0 + viewCount($1) }
    }

    // MARK: - Pieces

    func quote(_ text: String) -> String {
        var shown = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        if shown.count > maxTextLength {
            let extra = shown.count - maxTextLength
            shown = String(shown.prefix(maxTextLength)) + "…(+\(extra) chars)"
        }
        return "\"\(shown)\""
    }

    static func describe(_ flag: ViewDescription.Flag) -> String {
        switch flag {
        case .truncated: return "text truncated"
        case .ambiguousLayout: return "ambiguous layout"
        case .zeroSize: return "zero size"
        case .offscreen: return "outside its window"
        }
    }

    /// `x,y width×height`, to a tenth of a point.
    public static func frame(_ rect: CGRectCodable) -> String {
        "\(number(rect.x)),\(number(rect.y)) \(number(rect.width))×\(number(rect.height))"
    }

    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value < 0 ? "-inf" : "inf") }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        return String(rounded)
    }

    /// `#RRGGBBAA` as sent by the agent → `#RRGGBB`, with the opacity
    /// spelled out only when the color isn't opaque.
    public static func color(_ hex: String) -> String {
        guard hex.count == 9, hex.hasPrefix("#"), let alpha = UInt8(hex.suffix(2), radix: 16) else { return hex }
        let rgb = String(hex.prefix(7))
        return alpha == 255 ? rgb : "\(rgb)@\(Int((Double(alpha) / 255 * 100).rounded()))%"
    }

    public static func color(_ color: CGColorCodable) -> String {
        Self.color(color.hex)
    }

    /// Generic class names get long (`CellHostingView<ModifiedContent<…>>`);
    /// past a point the parameters stop helping.
    public static func shortClassName(_ name: String, limit: Int = 56) -> String {
        guard name.count > limit, let open = name.firstIndex(of: "<") else { return name }
        return name[..<open] + "<…>"
    }
}
