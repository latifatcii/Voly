#if canImport(UIKit) || os(macOS)
import Foundation

/// Changing the characters of styled text without touching its styling.
enum AttributedTextEdit {
    /// `styled` reading `text` instead. Only the characters that differ are
    /// replaced, so every run outside the edit keeps its attributes and the
    /// new characters take the attributes of the ones they replace (or, for a
    /// pure insertion, of the character before them).
    static func replacingText(in styled: NSAttributedString, with text: String) -> NSAttributedString {
        guard styled.length > 0 else { return NSAttributedString(string: text) }
        let old = styled.string as NSString
        let new = text as NSString
        let shorter = min(old.length, new.length)

        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        // Keep both halves of a surrogate pair on the same side of the edit.
        if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) {
            prefix -= 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) {
            suffix -= 1
        }

        let result = NSMutableAttributedString(attributedString: styled)
        result.replaceCharacters(
            in: NSRange(location: prefix, length: old.length - prefix - suffix),
            with: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        )
        return NSAttributedString(attributedString: result)
    }
}
#endif

#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime
import Darwin   // dladdr / Dl_info

/// Sets the text a view shows and leaves everything else about it alone.
///
/// UIKit's plain setters (`text`, `placeholder`, a button's title) restyle
/// the whole string from the view's own `font` and `textColor`, which drops
/// whatever the app put in the attributed string: line height, letter
/// spacing, a bold word, per-range colors. A text view that isn't selectable
/// can lose its font the same way. So the text is set the ordinary way —
/// app code that reacts to it still runs — and the styling it had is put
/// back if the setter dropped it.
@MainActor
final class TextStyleKeeper {
    /// The styling of text an edit emptied, so typing into it again brings
    /// the same styling back: an empty attributed string holds no attributes.
    @MainActor
    private final class Memory {
        let property: String
        let attributes: [NSAttributedString.Key: Any]
        let container: AttributeContainer?
        let state: UIControl.State
        /// The view's own font right after the edit; a different font later
        /// means the app restyled the view and this is out of date.
        let font: UIFont?

        init(
            property: String,
            attributes: [NSAttributedString.Key: Any] = [:],
            container: AttributeContainer? = nil,
            state: UIControl.State = .normal,
            font: UIFont? = nil
        ) {
            self.property = property
            self.attributes = attributes
            self.container = container
            self.state = state
            self.font = font
        }
    }

    private enum ButtonPart {
        case title, subtitle
    }

    @MainActor
    private final class Owner {
        weak var button: UIButton?
        let part: ButtonPart

        init(button: UIButton, part: ButtonPart) {
            self.button = button
            self.part = part
        }
    }

    private let memories = NSMapTable<UIView, Memory>.weakToStrongObjects()
    /// Labels known to be a button's title or subtitle. A button takes its
    /// label out of the hierarchy while the title is empty.
    private let owners = NSMapTable<UILabel, Owner>.weakToStrongObjects()

    init() {}

    /// Sets the string property `property` of `view` to `text`, keeping the
    /// styling of the text it replaces.
    ///
    /// - Returns: false when this isn't text with styling to keep (the view
    ///   has no `attributed…` counterpart of the property); nothing was
    ///   changed and the caller sets the value the ordinary way.
    func setText(_ text: String, property: String, on view: UIView) -> Bool {
        if property == "text", let label = view as? UILabel, let found = owner(of: label) {
            // A button owns its labels and rewrites them from its title on
            // the next layout, so the change has to go through the button.
            setText(text, part: found.part, on: found.button)
            return true
        }

        let twin = "attributed" + property.volyCapitalizedFirst
        let setter = NSSelectorFromString("set\(property.volyCapitalizedFirst):")
        guard view.responds(to: NSSelectorFromString(property)),
              view.responds(to: setter),
              view.responds(to: NSSelectorFromString(twin)),
              view.responds(to: NSSelectorFromString("set\(twin.volyCapitalizedFirst):"))
        else { return false }

        if (view.value(forKey: property) as? String) == text { return true }

        let before = (view.value(forKey: twin) as? NSAttributedString).map { NSAttributedString(attributedString: $0) }
        let styled = before.flatMap { $0.length > 0 ? $0 : nil }
        let wanted: NSAttributedString?
        if let styled {
            wanted = AttributedTextEdit.replacingText(in: styled, with: text)
        } else if let memory = memories.object(forKey: view), memory.property == property,
                  memory.font == Self.font(of: view) {
            wanted = NSAttributedString(string: text, attributes: memory.attributes)
        } else {
            wanted = nil
        }
        let setterIsAppCode = Self.isAppCode(setter, of: view)
        let fontBefore = Self.font(of: view)

        view.setValue(text, forKey: property)

        if text.isEmpty {
            if let styled {
                if Self.isPlain(styled) {
                    memories.removeObject(forKey: view)
                } else {
                    let memory = Memory(
                        property: property,
                        attributes: styled.attributes(at: 0, effectiveRange: nil),
                        font: Self.font(of: view)
                    )
                    memories.setObject(memory, forKey: view)
                }
            }
            return true
        }
        memories.removeObject(forKey: view)

        guard let wanted else {
            // No styled text to compare with; the view's own font is all
            // there is to keep.
            if !setterIsAppCode, let fontBefore, Self.font(of: view) != fontBefore,
               view.responds(to: NSSelectorFromString("setFont:")) {
                view.setValue(fontBefore, forKey: "font")
            }
            return true
        }
        let after = view.value(forKey: twin) as? NSAttributedString
        if Self.lostStyling(after, wanted: wanted, setterIsAppCode: setterIsAppCode) {
            view.setValue(wanted, forKey: twin)
        }
        return true
    }

    /// Sets a button configuration's title, in the attributes an attributed
    /// title starts with. Assigning `title` alone would drop them.
    static func setTitle(_ text: String, in configuration: inout UIButton.Configuration) {
        let attributes = Self.attributes(of: configuration.attributedTitle)
        set(text, part: .title, attributes: attributes, in: &configuration)
    }

    /// The same for the subtitle.
    static func setSubtitle(_ text: String, in configuration: inout UIButton.Configuration) {
        let attributes = Self.attributes(of: configuration.attributedSubtitle)
        set(text, part: .subtitle, attributes: attributes, in: &configuration)
    }

    // MARK: - Deciding whether styling was lost

    /// Whether setting the text left the view showing `after` where keeping
    /// the styling means `wanted`, in a way that should be put right.
    private static func lostStyling(
        _ after: NSAttributedString?,
        wanted: NSAttributedString,
        setterIsAppCode: Bool
    ) -> Bool {
        // The setter may format or reject the text; then it isn't ours to style.
        guard let after, after.string == wanted.string, !after.isEqual(to: wanted) else { return false }
        if isPlain(wanted) {
            // Nothing beyond the view's own font and color was there to lose.
            // Those survive a plain setter, except where UIKit resets them.
            return !setterIsAppCode
                && (value(.font, in: after) != value(.font, in: wanted)
                    || value(.foregroundColor, in: after) != value(.foregroundColor, in: wanted))
        }
        // An app's own setter may style the new text differently on purpose;
        // only falling back to no styling at all counts as losing it.
        return setterIsAppCode ? isPlain(after) : true
    }

    private static func value(_ key: NSAttributedString.Key, in text: NSAttributedString) -> NSObject? {
        guard text.length > 0 else { return nil }
        return text.attribute(key, at: 0, effectiveRange: nil) as? NSObject
    }

    /// True when the text carries nothing a view's own `font`, `textColor`,
    /// alignment and shadow couldn't express, so a plain setter keeps it all.
    private static func isPlain(_ text: NSAttributedString) -> Bool {
        guard text.length > 0 else { return true }
        var range = NSRange(location: 0, length: 0)
        let attributes = text.attributes(
            at: 0, longestEffectiveRange: &range, in: NSRange(location: 0, length: text.length)
        )
        guard range.length == text.length else { return false }
        for (key, value) in attributes {
            switch key {
            case .font, .foregroundColor, .shadow:
                continue
            case .paragraphStyle:
                guard let style = value as? NSParagraphStyle,
                      style.lineSpacing == 0, style.paragraphSpacing == 0, style.paragraphSpacingBefore == 0,
                      style.minimumLineHeight == 0, style.maximumLineHeight == 0, style.lineHeightMultiple == 0,
                      style.headIndent == 0, style.tailIndent == 0, style.firstLineHeadIndent == 0
                else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func font(of view: UIView) -> UIFont? {
        guard view.responds(to: NSSelectorFromString("font")) else { return nil }
        return view.value(forKey: "font") as? UIFont
    }

    /// Whether `selector` is implemented for `view` by the app (a subclass
    /// that overrides it, or the app's own view class) rather than by a
    /// system framework.
    private static func isAppCode(_ selector: Selector, of view: UIView) -> Bool {
        guard let implementation = class_getMethodImplementation(type(of: view), selector) else { return false }
        var info = Dl_info()
        let address = unsafeBitCast(implementation, to: UnsafeMutableRawPointer.self)
        guard dladdr(address, &info) != 0, let name = info.dli_fname else { return false }
        let path = String(cString: name)
        return !path.contains("/System/Library/") && !path.contains("/usr/lib/")
    }

    // MARK: - Buttons

    private func owner(of label: UILabel) -> (button: UIButton, part: ButtonPart)? {
        if let known = owners.object(forKey: label), let button = known.button {
            return (button, known.part)
        }
        var ancestor = label.superview
        for _ in 0..<2 {
            guard let current = ancestor else { return nil }
            if let button = current as? UIButton {
                let configuration = button.configuration
                // `titleLabel` creates the label when there is none; don't
                // ask a button that shows no text of its own.
                guard button.currentTitle != nil || button.currentAttributedTitle != nil
                    || configuration?.title != nil || configuration?.subtitle != nil
                else { return nil }
                let part: ButtonPart
                if button.titleLabel === label {
                    part = .title
                } else if configuration != nil, button.subtitleLabel === label {
                    part = .subtitle
                } else {
                    return nil
                }
                owners.setObject(Owner(button: button, part: part), forKey: label)
                return (button, part)
            }
            ancestor = current.superview
        }
        return nil
    }

    private func setText(_ text: String, part: ButtonPart, on button: UIButton) {
        defer { button.layoutIfNeeded() }
        guard var configuration = button.configuration else {
            setTitle(text, on: button)
            return
        }
        let property = part == .title ? "configuration.title" : "configuration.subtitle"
        let current = part == .title ? configuration.attributedTitle : configuration.attributedSubtitle
        if let current, String(current.characters) == text { return }

        var attributes = Self.attributes(of: current)
        if attributes == nil, let memory = memories.object(forKey: button), memory.property == property {
            attributes = memory.container
        }
        if !text.isEmpty {
            memories.removeObject(forKey: button)
        } else if let attributes {
            memories.setObject(Memory(property: property, container: attributes), forKey: button)
        }
        Self.set(text, part: part, attributes: attributes, in: &configuration)
        button.configuration = configuration
    }

    /// The attributes a configuration's text starts with; nil when it has none.
    private static func attributes(of text: AttributedString?) -> AttributeContainer? {
        guard let attributes = text?.runs.first?.attributes, attributes != AttributeContainer() else { return nil }
        return attributes
    }

    private static func set(
        _ text: String,
        part: ButtonPart,
        attributes: AttributeContainer?,
        in configuration: inout UIButton.Configuration
    ) {
        switch (part, attributes) {
        case (.title, let attributes?):
            configuration.attributedTitle = AttributedString(text, attributes: attributes)
        case (.title, nil):
            configuration.title = text
        case (.subtitle, let attributes?):
            configuration.attributedSubtitle = AttributedString(text, attributes: attributes)
        case (.subtitle, nil):
            configuration.subtitle = text
        }
    }

    /// A button without a configuration: titles are kept per control state,
    /// and an attributed title wins over a plain one.
    private func setTitle(_ text: String, on button: UIButton) {
        let property = "title"
        if let current = button.currentAttributedTitle, current.length > 0 {
            guard current.string != text else { return }
            // Write to the state the title on screen comes from.
            let state: UIControl.State = button.attributedTitle(for: .normal) == current ? .normal : button.state
            button.setAttributedTitle(AttributedTextEdit.replacingText(in: current, with: text), for: state)
            if text.isEmpty {
                let memory = Memory(
                    property: property, attributes: current.attributes(at: 0, effectiveRange: nil), state: state
                )
                memories.setObject(memory, forKey: button)
            } else {
                memories.removeObject(forKey: button)
            }
            return
        }
        if let memory = memories.object(forKey: button), memory.property == property {
            guard !text.isEmpty else { return }
            button.setAttributedTitle(NSAttributedString(string: text, attributes: memory.attributes), for: memory.state)
            memories.removeObject(forKey: button)
            return
        }
        guard button.currentTitle != text else { return }
        let state: UIControl.State = button.title(for: .normal) == button.currentTitle ? .normal : button.state
        button.setTitle(text, for: state)
    }
}
#endif
