import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

public struct PreviewConfig: Codable, Sendable, Hashable {
    public var size: CGSizeCodable
    public var safeAreaInsets: UIEdgeInsetsCodable
    public var orientation: Orientation
    public var userInterfaceStyle: UIStyle
    public var contentSizeCategory: ContentSize
    public var horizontalSizeClass: SizeClass
    public var verticalSizeClass: SizeClass
    public var displayScale: Double
    public var layoutDirection: LayoutDirection

    public init(
        size: CGSizeCodable,
        safeAreaInsets: UIEdgeInsetsCodable = .zero,
        orientation: Orientation = .portrait,
        userInterfaceStyle: UIStyle = .unspecified,
        contentSizeCategory: ContentSize = .unspecified,
        horizontalSizeClass: SizeClass = .unspecified,
        verticalSizeClass: SizeClass = .unspecified,
        displayScale: Double = 2.0,
        layoutDirection: LayoutDirection = .ltr
    ) {
        self.size = size
        self.safeAreaInsets = safeAreaInsets
        self.orientation = orientation
        self.userInterfaceStyle = userInterfaceStyle
        self.contentSizeCategory = contentSizeCategory
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.displayScale = displayScale
        self.layoutDirection = layoutDirection
    }

    public struct Applied: Codable, Sendable, Hashable {
        public let actualSize: CGSizeCodable
        public let warnings: [String]
        public init(actualSize: CGSizeCodable, warnings: [String]) {
            self.actualSize = actualSize
            self.warnings = warnings
        }
    }

    public enum Orientation: String, Codable, Sendable {
        case portrait, landscapeLeft, landscapeRight, portraitUpsideDown
    }
    public enum UIStyle: String, Codable, Sendable { case light, dark, unspecified }
    public enum ContentSize: String, Codable, Sendable {
        case xs, s, m, l, xl, xxl, xxxl, ax1, ax2, ax3, ax4, ax5, unspecified
    }
    public enum SizeClass: String, Codable, Sendable { case compact, regular, unspecified }
    public enum LayoutDirection: String, Codable, Sendable { case ltr, rtl }
}

public struct SourceInfo: Codable, Sendable, Hashable {
    public let className: String
    public let moduleName: String?
    public let dsymUUID: String?
    public let guessedRelativePath: String?
    /// Classes worth jumping to for this selection, most specific first: the
    /// view's own app-defined class, then app-defined owners. Empty when the
    /// selection and everything around it belongs to system frameworks.
    public let candidates: [SourceCandidate]?

    public init(
        className: String,
        moduleName: String?,
        dsymUUID: String?,
        guessedRelativePath: String?,
        candidates: [SourceCandidate]? = nil
    ) {
        self.className = className
        self.moduleName = moduleName
        self.dsymUUID = dsymUUID
        self.guessedRelativePath = guessedRelativePath
        self.candidates = candidates
    }
}

/// One class the host can try to resolve to a file and line.
public struct SourceCandidate: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable {
        /// The selected view's dynamic class.
        case viewClass
        /// An app-defined superclass of a system-class view.
        case superclass
        /// The view controller that owns the selected view.
        case viewController
        /// Nearest app-defined view above the selection.
        case ancestorView
    }

    /// A method implemented by the class, as an offset from the start of the
    /// binary image that contains it. The host turns this into a file address
    /// and asks the debug info for its line — no symbol names are guessed.
    public struct Probe: Codable, Sendable, Hashable {
        public let selector: String
        public let imageOffset: UInt64
        public init(selector: String, imageOffset: UInt64) {
            self.selector = selector
            self.imageOffset = imageOffset
        }
    }

    public let role: Role
    public let className: String
    public let moduleName: String?
    /// `NSStringFromClass` — module-qualified or mangled for Swift classes.
    public let runtimeName: String
    /// Host path of the Mach-O image that defines the class.
    public let imagePath: String
    public let imageUUID: String?
    public let probes: [Probe]

    public var id: String { "\(role.rawValue):\(runtimeName)" }

    public init(
        role: Role,
        className: String,
        moduleName: String?,
        runtimeName: String,
        imagePath: String,
        imageUUID: String?,
        probes: [Probe]
    ) {
        self.role = role
        self.className = className
        self.moduleName = moduleName
        self.runtimeName = runtimeName
        self.imagePath = imagePath
        self.imageUUID = imageUUID
        self.probes = probes
    }
}
