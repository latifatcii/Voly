import UIKit

/// Text styled the ways apps style it — runs in a label, letter spacing, a
/// blurred shadow, attributed button titles, an attributed placeholder, a
/// text view that isn't selectable — to see what editing the text through
/// Voly does to the styling.
///
/// Shown with `VOLY_SAMPLE_ROUTE=styled`. Next to each piece of text sits a
/// `StyleProbe` whose `report` property spells out the styling the text has
/// right now, so `scripts/text-style-test.sh` can read it back. For the
/// buttons, setting the probe's `appTitle` gives the button a new plain title
/// the way the app's own code would.
final class StyledTextDemoVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        func add(
            _ name: String, _ text: UIView, appSetsTitle: ((String) -> Void)? = nil, report: @escaping () -> String
        ) {
            text.accessibilityIdentifier = "styled.\(name)"
            let probe = StyleProbe(read: report, setTitle: appSetsTitle)
            probe.accessibilityIdentifier = "probe.\(name)"
            let row = UIStackView(arrangedSubviews: [text, probe])
            row.spacing = 4
            stack.addArrangedSubview(row)
        }

        // Three runs under one letter spacing and line height.
        let runs = UILabel()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        let total = NSMutableAttributedString(
            string: "Total due today",
            attributes: [.font: UIFont.systemFont(ofSize: 17), .kern: 1.5, .paragraphStyle: paragraph]
        )
        total.addAttributes(
            [.font: UIFont.boldSystemFont(ofSize: 17), .foregroundColor: UIColor.systemRed],
            range: NSRange(location: 6, length: 3)
        )
        runs.attributedText = total
        add("runs", runs) { [unowned runs] in StyleProbe.describe(runs.attributedText) }

        // One run: nothing but letter spacing beyond what the label has itself.
        let spaced = UILabel()
        spaced.attributedText = NSAttributedString(
            string: "ORDER", attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .kern: 3]
        )
        add("spaced", spaced) { [unowned spaced] in StyleProbe.describe(spaced.attributedText) }

        // A shadow with a blur, which a label's own shadow can't have.
        let glow = UILabel()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowColor = UIColor.systemBlue
        glow.attributedText = NSAttributedString(
            string: "Glow", attributes: [.font: UIFont.systemFont(ofSize: 20), .shadow: shadow]
        )
        add("glow", glow) { [unowned glow] in StyleProbe.describe(glow.attributedText) }

        // A configuration with a two-run title and a spaced subtitle.
        var configuration = UIButton.Configuration.filled()
        var title = AttributedString("Buy ")
        title.font = .systemFont(ofSize: 17)
        var pro = AttributedString("Pro")
        pro.font = .systemFont(ofSize: 17, weight: .heavy)
        configuration.attributedTitle = title + pro
        var subtitle = AttributedString("per month")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.uiKit.kern = 2
        configuration.attributedSubtitle = subtitle
        let buy = UIButton(configuration: configuration)
        add("buy", buy, appSetsTitle: { [unowned buy] in buy.configuration?.title = $0 }) { [unowned buy] in
            let configuration = buy.configuration
            return "title " + StyleProbe.describe(configuration?.attributedTitle.flatMap(StyleProbe.uiKit))
                + " subtitle " + StyleProbe.describe(configuration?.attributedSubtitle.flatMap(StyleProbe.uiKit))
        }

        // No configuration: an attributed title for the normal state.
        let signIn = UIButton(type: .system)
        signIn.setAttributedTitle(NSAttributedString(
            string: "Sign in",
            attributes: [.font: UIFont.systemFont(ofSize: 15), .underlineStyle: NSUnderlineStyle.single.rawValue, .kern: 1]
        ), for: .normal)
        add("signIn", signIn, appSetsTitle: { [unowned signIn] in
            signIn.setAttributedTitle(nil, for: .normal)
            signIn.setTitle($0, for: .normal)
        }) { [unowned signIn] in
            signIn.currentAttributedTitle.map { StyleProbe.describe($0) } ?? "plain \(signIn.currentTitle ?? "")"
        }

        // A text view that isn't selectable, in a font of its own.
        let notes = UITextView()
        notes.isScrollEnabled = false
        notes.isEditable = false
        notes.isSelectable = false
        notes.font = UIFont(name: "Georgia", size: 18)
        notes.text = "Notes"
        add("notes", notes) { [unowned notes] in
            "font \(notes.font?.fontName ?? "none") text " + StyleProbe.describe(notes.attributedText)
        }

        let email = UITextField()
        email.borderStyle = .roundedRect
        email.attributedPlaceholder = NSAttributedString(
            string: "Email", attributes: [.foregroundColor: UIColor.systemPurple, .kern: 2]
        )
        add("email", email) { [unowned email] in StyleProbe.describe(email.attributedPlaceholder) }
    }
}

/// Reports the styling of the text next to it through a property Voly reads.
final class StyleProbe: UIView {
    private let read: () -> String
    private let setTitle: ((String) -> Void)?

    init(read: @escaping () -> String, setTitle: ((String) -> Void)? = nil) {
        self.read = read
        self.setTitle = setTitle
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc var report: String { read() }

    /// Write-only in effect: stands in for app code that retitles the button.
    @objc var appTitle: String {
        get { "" }
        set { setTitle?(newValue) }
    }

    /// `Total {17 k1.5 lh1.2}|due{17B k1.5 lh1.2 red}|…`: each run's text, then
    /// its font size (B when bold), kern, line height, shadow blur, underline and color.
    static func describe(_ text: NSAttributedString?) -> String {
        guard let text, text.length > 0 else { return "empty" }
        var runs: [String] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var parts: [String] = []
            if let font = attributes[.font] as? UIFont {
                let bold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
                parts.append("\(Self.number(font.pointSize))\(bold ? "B" : "")")
            }
            if let kern = attributes[.kern] as? NSNumber, kern.doubleValue != 0 {
                parts.append("k\(Self.number(CGFloat(kern.doubleValue)))")
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.lineHeightMultiple != 0 {
                parts.append("lh\(Self.number(style.lineHeightMultiple))")
            }
            if let shadow = attributes[.shadow] as? NSShadow, shadow.shadowBlurRadius != 0 {
                parts.append("blur\(Self.number(shadow.shadowBlurRadius))")
            }
            if let underline = attributes[.underlineStyle] as? NSNumber, underline.intValue != 0 {
                parts.append("ul")
            }
            if let color = attributes[.foregroundColor] as? UIColor, let name = Self.name(of: color) {
                parts.append(name)
            }
            runs.append(text.attributedSubstring(from: range).string + "{" + parts.joined(separator: " ") + "}")
        }
        return runs.joined(separator: "|")
    }

    static func uiKit(_ text: AttributedString) -> NSAttributedString? {
        try? NSAttributedString(text, including: \.uiKit)
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Only for colors the demo sets itself; the label and placeholder defaults say nothing.
    private static func name(of color: UIColor) -> String? {
        for (named, name) in [(UIColor.systemRed, "red"), (UIColor.systemPurple, "purple")] where color == named {
            return name
        }
        return nil
    }
}
