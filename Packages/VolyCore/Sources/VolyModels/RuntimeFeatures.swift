import Foundation

// Payload types for the runtime features layered on top of inspection:
// capability reporting, localization overrides, screenshots, navigation.

// MARK: - Capabilities

/// What a connected agent can do in this particular process. Reported in the
/// handshake so the inspector can disable controls instead of failing late.
public struct AgentCapabilities: Codable, Sendable, Hashable {
    public enum InjectionMode: String, Codable, Sendable {
        /// Linked into the app via SwiftPM and started with `VolyAgent.start()`.
        case sdk
        /// Loaded as a dylib (launch bridge or an explicit relaunch).
        case injected
    }

    public let injectionMode: InjectionMode
    /// Resizable-screen preview. Needs `VolyAgent.wrap(original:)` in the app.
    public let previewHost: Bool
    public let localization: Bool
    public let screenshots: Bool
    public let navigation: Bool
    /// Agent reports binary images + method addresses for source lookup.
    public let sourceSymbols: Bool

    public init(
        injectionMode: InjectionMode,
        previewHost: Bool,
        localization: Bool,
        screenshots: Bool,
        navigation: Bool,
        sourceSymbols: Bool
    ) {
        self.injectionMode = injectionMode
        self.previewHost = previewHost
        self.localization = localization
        self.screenshots = screenshots
        self.navigation = navigation
        self.sourceSymbols = sourceSymbols
    }
}

// MARK: - Localization

public struct LocalizationLanguage: Codable, Sendable, Hashable, Identifiable {
    /// The `.lproj` name as shipped in the app, e.g. `ar`, `pt-BR`, `zh-Hans`.
    public let code: String
    public let displayName: String
    /// Script direction of the *language*. Independent of whether the UI is
    /// currently laid out right-to-left — see `LayoutDirectionMode`.
    public let isRightToLeft: Bool
    public var id: String { code }

    public init(code: String, displayName: String, isRightToLeft: Bool) {
        self.code = code
        self.displayName = displayName
        self.isRightToLeft = isRightToLeft
    }
}

/// How the UI's semantic layout direction is driven while a language override
/// is active. Kept separate from the language so "Arabic strings in an LTR
/// layout" and "English strings in an RTL layout" are both testable.
public enum LayoutDirectionMode: String, Codable, Sendable, CaseIterable {
    /// Leave the app's layout direction alone.
    case system
    /// Mirror the layout when the override language is right-to-left.
    case followLanguage
    case leftToRight
    case rightToLeft
}

public struct LocalizationRefreshResult: Codable, Sendable, Hashable {
    /// Controls whose text was swapped to the new language.
    public let updated: Int
    /// Text that matched no known localized value (formatted, plural,
    /// hard-coded, or user-entered) and was left untouched.
    public let unresolved: Int
    /// Same source text maps to several keys with different translations.
    public let ambiguous: Int
    public let notes: [String]

    public init(updated: Int, unresolved: Int, ambiguous: Int, notes: [String]) {
        self.updated = updated
        self.unresolved = unresolved
        self.ambiguous = ambiguous
        self.notes = notes
    }
}

public struct LocalizationState: Codable, Sendable, Hashable {
    public let available: [LocalizationLanguage]
    public let developmentLanguage: String?
    /// What the app resolves to with no override.
    public let systemLanguage: String?
    public let activeOverride: String?
    public let layoutDirectionMode: LayoutDirectionMode
    /// Layout direction the key window is actually using right now.
    public let isLayoutRightToLeft: Bool
    /// Lookup entry points intercepted on this runtime.
    public let interceptedLookups: [String]
    public let lastRefresh: LocalizationRefreshResult?

    public init(
        available: [LocalizationLanguage],
        developmentLanguage: String?,
        systemLanguage: String?,
        activeOverride: String?,
        layoutDirectionMode: LayoutDirectionMode,
        isLayoutRightToLeft: Bool,
        interceptedLookups: [String],
        lastRefresh: LocalizationRefreshResult?
    ) {
        self.available = available
        self.developmentLanguage = developmentLanguage
        self.systemLanguage = systemLanguage
        self.activeOverride = activeOverride
        self.layoutDirectionMode = layoutDirectionMode
        self.isLayoutRightToLeft = isLayoutRightToLeft
        self.interceptedLookups = interceptedLookups
        self.lastRefresh = lastRefresh
    }
}

public struct LocalizationOverrideRequest: Codable, Sendable, Hashable {
    /// `nil` clears the override and restores the app's own behaviour.
    public let language: String?
    public let layoutDirectionMode: LayoutDirectionMode
    /// Re-apply known localized strings to visible controls afterwards.
    public let refreshUI: Bool

    public init(language: String?, layoutDirectionMode: LayoutDirectionMode, refreshUI: Bool) {
        self.language = language
        self.layoutDirectionMode = layoutDirectionMode
        self.refreshUI = refreshUI
    }
}

// MARK: - Screenshots

public enum ScreenshotTarget: Codable, Sendable, Hashable {
    /// The app's own windows, composited, without Voly's overlays.
    case application
    case view(ObjectID)
}

public enum InterfaceOrientation: String, Codable, Sendable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight, unknown
}

public struct ScreenshotImage: Codable, Sendable, Hashable {
    public let png: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double
    public let orientation: InterfaceOrientation

    public init(png: Data, pixelWidth: Int, pixelHeight: Int, scale: Double, orientation: InterfaceOrientation) {
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.orientation = orientation
    }
}

public struct ScreenInfo: Codable, Sendable, Hashable {
    public let orientation: InterfaceOrientation
    public let scale: Double
    public init(orientation: InterfaceOrientation, scale: Double) {
        self.orientation = orientation
        self.scale = scale
    }
}

// MARK: - Navigation

public enum NavigationAction: String, Codable, Sendable, CaseIterable {
    case dismiss, pop, popToRoot
}

public struct NavigationState: Codable, Sendable, Hashable {
    public let canDismiss: Bool
    public let canPop: Bool
    public let canPopToRoot: Bool
    /// Why each action is unavailable, keyed by `NavigationAction.rawValue`.
    public let unavailableReasons: [String: String]
    public let topViewController: String?
    public let navigationStackDepth: Int?
    public let isTransitioning: Bool

    public init(
        canDismiss: Bool,
        canPop: Bool,
        canPopToRoot: Bool,
        unavailableReasons: [String: String],
        topViewController: String?,
        navigationStackDepth: Int?,
        isTransitioning: Bool
    ) {
        self.canDismiss = canDismiss
        self.canPop = canPop
        self.canPopToRoot = canPopToRoot
        self.unavailableReasons = unavailableReasons
        self.topViewController = topViewController
        self.navigationStackDepth = navigationStackDepth
        self.isTransitioning = isTransitioning
    }

    public func isAvailable(_ action: NavigationAction) -> Bool {
        switch action {
        case .dismiss: return canDismiss
        case .pop: return canPop
        case .popToRoot: return canPopToRoot
        }
    }

    public static let unavailable = NavigationState(
        canDismiss: false, canPop: false, canPopToRoot: false,
        unavailableReasons: [:], topViewController: nil,
        navigationStackDepth: nil, isTransitioning: false
    )
}

public struct NavigationResult: Codable, Sendable, Hashable {
    public let action: NavigationAction
    public let performed: Bool
    public let message: String?
    /// State right after the action was started (a transition may still be
    /// running; ask again for the settled state).
    public let state: NavigationState

    public init(action: NavigationAction, performed: Bool, message: String?, state: NavigationState) {
        self.action = action
        self.performed = performed
        self.message = message
        self.state = state
    }
}
