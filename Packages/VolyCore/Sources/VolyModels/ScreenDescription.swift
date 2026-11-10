import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

// A description of what is on screen, made for reading rather than for
// driving the inspector UI: every view with the things a person (or an AI
// agent) would otherwise have to guess from a screenshot — its text, font,
// colors, exact frame, state, and anything that looks wrong.

public struct ScreenDescriptionRequest: Codable, Sendable, Hashable {
    /// Describe only this view's subtree. Nil describes every window.
    public var rootID: ObjectID?
    /// Levels below the root(s) to include. Nil means all.
    public var maxDepth: Int?
    /// Include hidden / fully transparent views and their subtrees.
    public var includeHidden: Bool
    /// Ask Auto Layout whether each constrained view's layout is ambiguous.
    public var checkLayout: Bool
    /// Read what assistive technology sees inside views whose content is not
    /// made of UIKit subviews (SwiftUI, custom drawing).
    public var includeAccessibility: Bool

    public init(
        rootID: ObjectID? = nil, maxDepth: Int? = nil, includeHidden: Bool = false,
        checkLayout: Bool = true, includeAccessibility: Bool = true
    ) {
        self.rootID = rootID
        self.maxDepth = maxDepth
        self.includeHidden = includeHidden
        self.checkLayout = checkLayout
        self.includeAccessibility = includeAccessibility
    }

    // Older hosts don't send the newer switches.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootID = try container.decodeIfPresent(ObjectID.self, forKey: .rootID)
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
        includeHidden = try container.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? false
        checkLayout = try container.decodeIfPresent(Bool.self, forKey: .checkLayout) ?? true
        includeAccessibility = try container.decodeIfPresent(Bool.self, forKey: .includeAccessibility) ?? true
    }
}

public struct ViewDescription: Codable, Sendable, Hashable, Identifiable {
    /// Something about the view that usually means a layout bug.
    public enum Flag: String, Codable, Sendable {
        /// Text doesn't fit its label and is cut off.
        case truncated
        /// Auto Layout can't determine a unique frame.
        case ambiguousLayout
        /// Visible, but zero wide or tall.
        case zeroSize
        /// Entirely outside its window (and not inside a scroll view).
        case offscreen
    }

    public let id: ObjectID
    public let className: String
    public var accessibilityIdentifier: String?
    public var accessibilityLabel: String?
    /// Class of the view controller whose root view this is.
    public var viewController: String?
    /// In window coordinates, in points.
    public var frame: CGRectCodable
    public var isHidden: Bool
    public var alpha: Double
    public var text: String?
    public var placeholder: String?
    /// Non-text state of a control: a switch's on/off, a slider's value,
    /// the selected segment.
    public var value: String?
    /// e.g. `System Semibold 17`.
    public var font: String?
    public var textColor: String?
    public var backgroundColor: String?
    public var tintColor: String?
    public var textAlignment: String?
    public var numberOfLines: Int?
    public var cornerRadius: Double?
    public var borderWidth: Double?
    public var borderColor: String?
    /// Size in points of the image a view shows, and how it is fitted,
    /// e.g. `64×64 scaleAspectFit`.
    public var image: String?
    /// A stack view's arrangement, e.g. `vertical spacing=12 alignment=fill
    /// distribution=fill`.
    public var stack: String?
    /// A scroll view's content, e.g. `content 393×1840 offset 0,212`.
    public var scroll: String?
    /// How the view takes part in layout. Only filled in for the view a
    /// request was rooted at.
    public var layout: LayoutDetails?
    /// `disabled`, `selected`, `highlighted`, and `secure` for a password
    /// field (whose `text` is then a placeholder, never what was typed).
    public var state: [String]
    public var flags: [Flag]
    public var clipsToBounds: Bool
    public var children: [ViewDescription]
    /// Children left out: hidden, or below the requested depth.
    public var omittedChildren: Int
    /// What assistive technology sees inside a view whose content isn't made
    /// of UIKit subviews (a SwiftUI hosting view, a custom-drawn view).
    public var accessibilityElements: [AccessibilityElementDescription]?

    public init(id: ObjectID, className: String, frame: CGRectCodable, isHidden: Bool, alpha: Double, clipsToBounds: Bool) {
        self.id = id
        self.className = className
        self.frame = frame
        self.isHidden = isHidden
        self.alpha = alpha
        self.clipsToBounds = clipsToBounds
        self.state = []
        self.flags = []
        self.children = []
        self.omittedChildren = 0
    }
}

/// Inputs to Auto Layout that don't show in a frame.
public struct LayoutDetails: Codable, Sendable, Hashable {
    public let bounds: CGRectCodable
    /// False when the frame is set by hand / autoresizing masks.
    public let usesAutoLayout: Bool
    /// Nil on an axis the view has no intrinsic size for.
    public let intrinsicWidth: Double?
    public let intrinsicHeight: Double?
    public let huggingHorizontal: Float
    public let huggingVertical: Float
    public let compressionResistanceHorizontal: Float
    public let compressionResistanceVertical: Float
    public let safeAreaInsets: UIEdgeInsetsCodable
    public let layoutMargins: UIEdgeInsetsCodable
    /// The layout inputs in the platform's own words, when the fields above
    /// don't describe them — Android has layout params, padding and
    /// margins rather than intrinsic size and hugging priorities.
    public let summary: String?

    public init(
        bounds: CGRectCodable, usesAutoLayout: Bool, intrinsicWidth: Double?, intrinsicHeight: Double?,
        huggingHorizontal: Float, huggingVertical: Float,
        compressionResistanceHorizontal: Float, compressionResistanceVertical: Float,
        safeAreaInsets: UIEdgeInsetsCodable, layoutMargins: UIEdgeInsetsCodable,
        summary: String? = nil
    ) {
        self.bounds = bounds
        self.usesAutoLayout = usesAutoLayout
        self.intrinsicWidth = intrinsicWidth
        self.intrinsicHeight = intrinsicHeight
        self.huggingHorizontal = huggingHorizontal
        self.huggingVertical = huggingVertical
        self.compressionResistanceHorizontal = compressionResistanceHorizontal
        self.compressionResistanceVertical = compressionResistanceVertical
        self.safeAreaInsets = safeAreaInsets
        self.layoutMargins = layoutMargins
        self.summary = summary
    }
}

/// One step on the way from a window down to a view.
public struct ViewAncestor: Codable, Sendable, Hashable {
    public let id: ObjectID
    public let className: String
    public let viewController: String?

    public init(id: ObjectID, className: String, viewController: String?) {
        self.id = id
        self.className = className
        self.viewController = viewController
    }
}

public struct AccessibilityElementDescription: Codable, Sendable, Hashable {
    public let label: String?
    public let value: String?
    public let identifier: String?
    /// `button`, `header`, `image`, `staticText`, `selected`, …
    public let traits: [String]
    /// In window coordinates, in points.
    public let frame: CGRectCodable

    public init(label: String?, value: String?, identifier: String? = nil, traits: [String], frame: CGRectCodable) {
        self.label = label
        self.value = value
        self.identifier = identifier
        self.traits = traits
        self.frame = frame
    }
}

public struct ScreenDescription: Codable, Sendable, Hashable {
    public let appName: String
    public let bundleIdentifier: String?
    /// Size of the scene in points, in the current orientation.
    public let screenSize: CGSizeCodable
    public let scale: Double
    public let orientation: InterfaceOrientation
    /// `light` or `dark`.
    public let appearance: String
    public let contentSizeCategory: String
    /// The view controller the user is looking at.
    public let topViewController: String?
    /// One entry per window (or the single requested root).
    public let roots: [ViewDescription]
    /// For a request rooted at one view: its superviews, window first.
    public let ancestors: [ViewAncestor]?
    public let viewCount: Int
    /// True when the tree was cut off at the view limit.
    public let isTruncated: Bool

    public init(
        appName: String, bundleIdentifier: String?, screenSize: CGSizeCodable, scale: Double,
        orientation: InterfaceOrientation, appearance: String, contentSizeCategory: String,
        topViewController: String?, roots: [ViewDescription], ancestors: [ViewAncestor]? = nil,
        viewCount: Int, isTruncated: Bool
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.screenSize = screenSize
        self.scale = scale
        self.orientation = orientation
        self.appearance = appearance
        self.contentSizeCategory = contentSizeCategory
        self.topViewController = topViewController
        self.roots = roots
        self.ancestors = ancestors
        self.viewCount = viewCount
        self.isTruncated = isTruncated
    }
}
