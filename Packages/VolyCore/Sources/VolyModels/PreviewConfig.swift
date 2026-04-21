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

    public init(className: String, moduleName: String?, dsymUUID: String?, guessedRelativePath: String?) {
        self.className = className
        self.moduleName = moduleName
        self.dsymUUID = dsymUUID
        self.guessedRelativePath = guessedRelativePath
    }
}
