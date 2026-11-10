#if canImport(UIKit)
import UIKit
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

/// Builds a `ScreenDescription`: the live view tree with the content and
/// styling of each view, and flags for the usual layout suspects.
///
/// Read-only. Everything is taken from public UIKit state on the main actor;
/// the one potentially slow question (`hasAmbiguousLayout`) is only asked of
/// views that take part in Auto Layout, and the whole walk is capped.
@MainActor
struct ScreenDescriber {
    static let maxViews = 2500
    private static let maxAccessibilityElements = 200

    let registry: ObjectRegistry
    private var remaining = ScreenDescriber.maxViews
    private var count = 0

    init(registry: ObjectRegistry) {
        self.registry = registry
    }

    /// - Parameter topViewController: the screen the user is looking at, as
    ///   the navigation controller works it out.
    mutating func describe(_ request: ScreenDescriptionRequest, topViewController: String?) throws -> ScreenDescription {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first

        let roots: [UIView]
        var ancestors: [ViewAncestor]?
        if let rootID = request.rootID {
            guard let view = registry.object(for: rootID) as? UIView else {
                throw InspectorError.objectGone(rootID)
            }
            roots = [view]
            ancestors = sequence(first: view.superview, next: { $0?.superview })
                .compactMap { $0 }
                .reversed()
                .map { ViewAncestor(
                    id: registry.id(for: $0),
                    className: String(describing: type(of: $0)),
                    viewController: Self.owningController(of: $0)
                ) }
        } else {
            roots = scenes
                .flatMap(\.windows)
                .filter { !$0.isVolyOverlay && (request.includeHidden || !$0.isHidden) }
                .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        }

        var described = roots.compactMap { describe($0, depth: 0, request: request, insideScrollView: false) }
        if request.rootID != nil, let view = roots.first, !described.isEmpty {
            described[0].layout = Self.layoutDetails(of: view)
        }
        let traits = scene?.traitCollection ?? UITraitCollection.current
        let bounds = scene?.coordinateSpace.bounds ?? .zero
        return ScreenDescription(
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            screenSize: CGSizeCodable(bounds.size),
            scale: Double(scene?.screen.scale ?? 1),
            orientation: ScreenshotRenderer.screenInfo().orientation,
            appearance: traits.userInterfaceStyle == .dark ? "dark" : "light",
            contentSizeCategory: traits.preferredContentSizeCategory.rawValue
                .replacingOccurrences(of: "UICTContentSizeCategory", with: ""),
            topViewController: topViewController,
            roots: described,
            ancestors: ancestors,
            viewCount: count,
            isTruncated: remaining <= 0
        )
    }

    // MARK: - One view

    private mutating func describe(
        _ view: UIView,
        depth: Int,
        request: ScreenDescriptionRequest,
        insideScrollView: Bool
    ) -> ViewDescription? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        count += 1

        let frame = view.window == nil ? view.frame : view.convert(view.bounds, to: nil)
        var node = ViewDescription(
            id: registry.id(for: view),
            className: String(describing: type(of: view)),
            frame: CGRectCodable(frame),
            isHidden: view.isHidden,
            alpha: Double(view.alpha),
            clipsToBounds: view.clipsToBounds
        )
        node.accessibilityIdentifier = view.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        node.viewController = Self.owningController(of: view)
        node.backgroundColor = Self.hex(view.backgroundColor, in: view)
        if view.layer.cornerRadius > 0 { node.cornerRadius = Double(view.layer.cornerRadius) }
        if view.layer.borderWidth > 0 {
            node.borderWidth = Double(view.layer.borderWidth)
            node.borderColor = view.layer.borderColor.flatMap { CGColorCodable($0)?.hex }
        }
        describeContent(of: view, into: &node)

        // The usual suspects.
        let visible = !view.isHidden && view.alpha > 0.01
        if visible, frame.width == 0 || frame.height == 0, Self.shouldHaveSize(view, node) {
            node.flags.append(.zeroSize)
        }
        if visible, !insideScrollView, let window = view.window, view !== window,
           frame.width > 0, frame.height > 0, !window.bounds.intersects(frame) {
            node.flags.append(.offscreen)
        }
        if request.checkLayout, visible, !view.translatesAutoresizingMaskIntoConstraints, view.window != nil,
           view.hasAmbiguousLayout {
            node.flags.append(.ambiguousLayout)
        }

        // Children.
        let isLeafControl = Self.hidesItsSubviews(view, described: node)
        let subviews = isLeafControl ? [] : view.subviews.filter { !$0.isVolyOverlay }
        let shown = request.includeHidden ? subviews : subviews.filter { !$0.isHidden && $0.alpha > 0.01 }
        node.omittedChildren = subviews.count - shown.count
        if let maxDepth = request.maxDepth, depth >= maxDepth {
            node.omittedChildren += shown.count
        } else {
            let scrolling = insideScrollView || view is UIScrollView
            for child in shown {
                if let described = describe(child, depth: depth + 1, request: request, insideScrollView: scrolling) {
                    node.children.append(described)
                } else {
                    node.omittedChildren += 1
                }
            }
        }

        if request.includeAccessibility, !isLeafControl, visible,
           node.children.isEmpty || Self.drawsItsOwnContent(view) {
            node.accessibilityElements = accessibilityElements(of: view)
        }
        return node
    }

    /// Text, fonts, colors and control state for the UIKit classes that
    /// carry them.
    private func describeContent(of view: UIView, into node: inout ViewDescription) {
        if let label = view.accessibilityLabel, !label.isEmpty { node.accessibilityLabel = label }

        switch view {
        case let label as UILabel:
            node.text = label.text
            node.font = Self.describe(label.font)
            node.textColor = Self.hex(label.textColor, in: view)
            node.numberOfLines = label.numberOfLines
            node.textAlignment = Self.describe(label.textAlignment)
            if Self.isTruncated(label) { node.flags.append(.truncated) }
        case let button as UIButton:
            node.text = button.configuration?.title ?? button.title(for: button.state) ?? button.currentTitle
                ?? button.titleLabel?.text
            node.font = Self.describe(button.titleLabel?.font)
            // The label holds what is actually drawn; a configuration's
            // colors go through its style first (a filled button's title is
            // white whatever the tint).
            let drawnColor = button.titleLabel.flatMap { $0.text?.isEmpty == false ? $0.textColor : nil }
            node.textColor = Self.hex(
                drawnColor ?? button.configuration?.baseForegroundColor ?? button.currentTitleColor, in: view
            )
            if let image = button.configuration?.image ?? button.currentImage { node.image = Self.describe(image) }
            if node.backgroundColor == nil, let background = Self.configurationBackground(of: button) {
                node.backgroundColor = Self.hex(background.backgroundColor, in: background)
                if node.cornerRadius == nil, background.layer.cornerRadius > 0 {
                    node.cornerRadius = Double(background.layer.cornerRadius)
                }
            }
            if let title = button.titleLabel, title.window != nil, Self.isTruncated(title) {
                node.flags.append(.truncated)
            }
        case let field as UITextField:
            // What is typed into a password field stays in the app.
            if field.isSecureTextEntry {
                node.text = field.text.flatMap { $0.isEmpty ? nil : "(secure text, \($0.count) characters)" }
                node.state.append("secure")
            } else {
                node.text = field.text
            }
            node.placeholder = field.placeholder
            node.font = Self.describe(field.font)
            node.textColor = Self.hex(field.textColor, in: view)
            node.textAlignment = Self.describe(field.textAlignment)
        case let textView as UITextView:
            node.text = textView.text
            node.font = Self.describe(textView.font)
            node.textColor = Self.hex(textView.textColor, in: view)
            node.textAlignment = Self.describe(textView.textAlignment)
        case let imageView as UIImageView:
            node.image = imageView.image.map { "\(Self.describe($0)) \(Self.describe(imageView.contentMode))" }
            node.tintColor = Self.hex(imageView.tintColor, in: view)
        case let stack as UIStackView:
            node.stack = Self.describe(stack)
        case let toggle as UISwitch:
            node.value = toggle.isOn ? "on" : "off"
        case let slider as UISlider:
            node.value = "\(slider.value) in \(slider.minimumValue)…\(slider.maximumValue)"
        case let segmented as UISegmentedControl:
            let titles = (0..<segmented.numberOfSegments).map { segmented.titleForSegment(at: $0) ?? "image" }
            node.text = titles.joined(separator: " | ")
            if segmented.selectedSegmentIndex >= 0, segmented.selectedSegmentIndex < titles.count {
                node.value = "selected: \(titles[segmented.selectedSegmentIndex])"
            }
        case let stepper as UIStepper:
            node.value = "\(stepper.value)"
        case let progress as UIProgressView:
            node.value = "\(progress.progress)"
        case let page as UIPageControl:
            node.value = "page \(page.currentPage + 1) of \(page.numberOfPages)"
        case let searchBar as UISearchBar:
            node.text = searchBar.text
            node.placeholder = searchBar.placeholder
        case let bar as UINavigationBar:
            node.text = bar.topItem?.title
        default:
            break
        }
        if node.text?.isEmpty == true { node.text = nil }
        if let scroll = view as? UIScrollView {
            let size = scroll.contentSize, offset = scroll.contentOffset
            node.scroll = "content \(Int(size.width))×\(Int(size.height)) offset \(Int(offset.x)),\(Int(offset.y))"
        }

        if let control = view as? UIControl {
            if !control.isEnabled { node.state.append("disabled") }
            if control.isSelected { node.state.append("selected") }
            if control.isHighlighted { node.state.append("highlighted") }
        }
        if let cell = view as? UITableViewCell, cell.isSelected { node.state.append("selected") }
        if let cell = view as? UICollectionViewCell, cell.isSelected { node.state.append("selected") }
    }

    // MARK: - Helpers

    /// Controls whose subviews are implementation detail; their content is
    /// already on the control's own line.
    private static func hidesItsSubviews(_ view: UIView, described node: ViewDescription) -> Bool {
        if view is UIButton {
            // A button we could read nothing from (custom content, private
            // bar buttons) is described through its subviews instead.
            return node.text != nil || node.image != nil
        }
        return view is UILabel || view is UISwitch || view is UISlider
            || view is UISegmentedControl || view is UIStepper || view is UITextField
            || view is UIProgressView || view is UIPageControl || view is UIImageView
            || view is UIActivityIndicatorView
    }

    /// A configuration-styled button paints its fill in a background view
    /// of its own, not in `backgroundColor`.
    private static func configurationBackground(of button: UIButton) -> UIView? {
        guard button.configuration != nil else { return nil }
        func search(_ view: UIView, depth: Int) -> UIView? {
            for subview in view.subviews where !(subview is UILabel) && !(subview is UIImageView) {
                if let color = subview.backgroundColor, color.cgColor.alpha > 0, !subview.isHidden { return subview }
                if depth < 2, let found = search(subview, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(button, depth: 0)
    }

    /// Views that render their content themselves instead of through UIKit
    /// subviews: SwiftUI hosting views, and anything with a custom draw.
    private static func drawsItsOwnContent(_ view: UIView) -> Bool {
        String(describing: type(of: view)).contains("HostingView")
    }

    /// Zero size is only worth a flag on views meant to show something.
    /// UIKit keeps plenty of empty private helpers around.
    private static func shouldHaveSize(_ view: UIView, _ node: ViewDescription) -> Bool {
        guard !node.className.hasPrefix("_") else { return false }
        return node.text != nil || node.placeholder != nil || node.image != nil
            || view is UIControl || !view.subviews.isEmpty
    }

    private static func owningController(of view: UIView) -> String? {
        guard let controller = view.next as? UIViewController, controller.viewIfLoaded === view else { return nil }
        return String(describing: type(of: controller))
    }

    private static func layoutDetails(of view: UIView) -> LayoutDetails {
        let intrinsic = view.intrinsicContentSize
        func insets(_ value: UIEdgeInsets) -> UIEdgeInsetsCodable {
            UIEdgeInsetsCodable(
                top: Double(value.top), left: Double(value.left),
                bottom: Double(value.bottom), right: Double(value.right)
            )
        }
        return LayoutDetails(
            bounds: CGRectCodable(view.bounds),
            usesAutoLayout: !view.translatesAutoresizingMaskIntoConstraints,
            intrinsicWidth: intrinsic.width == UIView.noIntrinsicMetric ? nil : Double(intrinsic.width),
            intrinsicHeight: intrinsic.height == UIView.noIntrinsicMetric ? nil : Double(intrinsic.height),
            huggingHorizontal: view.contentHuggingPriority(for: .horizontal).rawValue,
            huggingVertical: view.contentHuggingPriority(for: .vertical).rawValue,
            compressionResistanceHorizontal: view.contentCompressionResistancePriority(for: .horizontal).rawValue,
            compressionResistanceVertical: view.contentCompressionResistancePriority(for: .vertical).rawValue,
            safeAreaInsets: insets(view.safeAreaInsets),
            layoutMargins: insets(view.layoutMargins)
        )
    }

    private static func describe(_ stack: UIStackView) -> String {
        let alignment: String
        switch stack.alignment {
        case .fill: alignment = "fill"
        case .leading: alignment = stack.axis == .vertical ? "leading" : "top"
        case .center: alignment = "center"
        case .trailing: alignment = stack.axis == .vertical ? "trailing" : "bottom"
        case .firstBaseline: alignment = "firstBaseline"
        case .lastBaseline: alignment = "lastBaseline"
        @unknown default: alignment = "unknown"
        }
        let distribution: String
        switch stack.distribution {
        case .fill: distribution = "fill"
        case .fillEqually: distribution = "fillEqually"
        case .fillProportionally: distribution = "fillProportionally"
        case .equalSpacing: distribution = "equalSpacing"
        case .equalCentering: distribution = "equalCentering"
        @unknown default: distribution = "unknown"
        }
        let spacing = stack.spacing == stack.spacing.rounded() ? String(Int(stack.spacing)) : String(format: "%.1f", stack.spacing)
        return "\(stack.axis == .vertical ? "vertical" : "horizontal") spacing=\(spacing) alignment=\(alignment) distribution=\(distribution)"
    }

    private static func describe(_ mode: UIView.ContentMode) -> String {
        switch mode {
        case .scaleToFill: return "scaleToFill"
        case .scaleAspectFit: return "scaleAspectFit"
        case .scaleAspectFill: return "scaleAspectFill"
        case .center: return "center"
        default: return "contentMode(\(mode.rawValue))"
        }
    }

    private static func isTruncated(_ label: UILabel) -> Bool {
        // A label nobody can see isn't cutting anything off.
        guard !label.isHidden, label.alpha > 0.01, label.bounds.height > 0 else { return false }
        guard let text = label.text, !text.isEmpty, label.bounds.width > 0 else { return false }
        let unlimited = label.textRect(
            forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude),
            limitedToNumberOfLines: 0
        )
        if label.numberOfLines == 1 {
            let oneLine = label.textRect(
                forBounds: CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                limitedToNumberOfLines: 1
            )
            return oneLine.width > label.bounds.width + 0.5
        }
        return unlimited.height > label.bounds.height + 0.5
    }

    private static func describe(_ font: UIFont?) -> String? {
        guard let font else { return nil }
        var name = font.fontName
        if name.hasPrefix(".") {
            // System font: ".SFUI-Semibold" → "System Semibold".
            let weight = name.split(separator: "-").dropFirst().joined(separator: "-")
            name = weight.isEmpty ? "System" : "System \(weight)"
        }
        let size = font.pointSize == font.pointSize.rounded() ? String(Int(font.pointSize)) : String(format: "%.1f", font.pointSize)
        return "\(name) \(size)"
    }

    private static func describe(_ alignment: NSTextAlignment) -> String? {
        switch alignment {
        case .center: return "center"
        case .right: return "right"
        case .justified: return "justified"
        case .left: return "left"
        default: return nil   // natural: the default, not worth a word
        }
    }

    private static func describe(_ image: UIImage) -> String {
        let size = "\(Int(image.size.width))×\(Int(image.size.height))"
        return image.isSymbolImage ? "symbol \(size)" : size
    }

    /// Hex of a color as this view resolves it (light/dark), or nil when it
    /// is absent or fully transparent.
    private static func hex(_ color: UIColor?, in view: UIView) -> String? {
        guard let color else { return nil }
        let resolved = color.resolvedColor(with: view.traitCollection).cgColor
        guard resolved.alpha > 0, let codable = CGColorCodable(resolved) else { return nil }
        return codable.hex
    }

    // MARK: - Accessibility elements

    /// For a view with no UIKit subviews, what assistive technology would
    /// read inside it. This is how SwiftUI content becomes visible here.
    private func accessibilityElements(of view: UIView) -> [AccessibilityElementDescription]? {
        guard let window = view.window else { return nil }
        var result: [AccessibilityElementDescription] = []
        collect(from: view, root: view, window: window, depth: 0, into: &result)
        return result.isEmpty ? nil : result
    }

    private func collect(from container: NSObject, root: UIView, window: UIWindow, depth: Int,
                         into result: inout [AccessibilityElementDescription]) {
        guard depth < 12, result.count < Self.maxAccessibilityElements else { return }
        let elements: [Any]
        if let listed = container.accessibilityElements {
            elements = listed
        } else {
            let count = container.accessibilityElementCount()
            guard count != NSNotFound, count > 0 else { return }
            elements = (0..<min(count, Self.maxAccessibilityElements)).compactMap {
                container.accessibilityElement(at: $0)
            }
        }
        for case let element as NSObject in elements {
            guard result.count < Self.maxAccessibilityElements else { return }
            // Subviews are described as views in their own right.
            if let subview = element as? UIView, subview !== root, subview.isDescendant(of: root) { continue }
            if element.isAccessibilityElement {
                let frame = window.screen.coordinateSpace.convert(element.accessibilityFrame, to: window)
                let identifier = (element as? UIAccessibilityIdentification)?.accessibilityIdentifier
                result.append(AccessibilityElementDescription(
                    label: element.accessibilityLabel,
                    value: element.accessibilityValue,
                    identifier: identifier.flatMap { $0.isEmpty ? nil : $0 },
                    traits: Self.describe(element.accessibilityTraits),
                    frame: CGRectCodable(frame)
                ))
            } else {
                collect(from: element, root: root, window: window, depth: depth + 1, into: &result)
            }
        }
    }

    /// SwiftUI (and UIKit's own labels) only build their accessibility tree
    /// once application accessibility is switched on — the switch Xcode's
    /// Accessibility Inspector and UI tests flip. It is a simulator-wide
    /// preference, so this is simulator-only and happens the first time a
    /// description with accessibility is asked for, never at load.
    ///
    /// - Returns: true when this call switched it on (the app needs a
    ///   moment to load its accessibility support before the first read).
    static func enableApplicationAccessibility() -> Bool {
        #if targetEnvironment(simulator)
        typealias Getter = @convention(c) () -> UInt8
        typealias Setter = @convention(c) (UInt8) -> Void
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let getter = dlsym(anyImage, "_AXSApplicationAccessibilityEnabled"),
              let setter = dlsym(anyImage, "_AXSApplicationAccessibilitySetEnabled")
        else { return false }
        guard unsafeBitCast(getter, to: Getter.self)() == 0 else { return false }
        unsafeBitCast(setter, to: Setter.self)(1)
        return true
        #else
        return false
        #endif
    }

    private static func describe(_ traits: UIAccessibilityTraits) -> [String] {
        let names: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.image, "image"),
            (.staticText, "staticText"), (.searchField, "searchField"), (.selected, "selected"),
            (.notEnabled, "disabled"), (.adjustable, "adjustable"), (.tabBar, "tabBar"),
        ]
        return names.filter { traits.contains($0.0) }.map(\.1)
    }
}
#endif
