#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime
import OSLog
import os
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.VolyAgent", category: "Localization")

/// In-memory language override for the host app.
///
/// Nothing on disk changes and nothing is hooked until the first override is
/// requested. From then on `NSBundle` string lookups made by bundles *inside
/// the app* are answered from the chosen `.lproj`; lookups by system
/// frameworks, and every lookup once the override is cleared, go straight to
/// the original implementation.
///
/// Changing the lookup language does not touch text UIKit controls already
/// hold, so `refreshVisibleUI()` re-resolves what it can prove came from a
/// localization table and leaves everything else (user input, formatted and
/// hard-coded text) exactly as it is.
@MainActor
public final class VolyLocalizationManager {
    /// Posted on the main thread after the override changes, for apps that
    /// want to rebuild localized content themselves. `userInfo["language"]`
    /// is the new code, absent when the override was cleared.
    public static let didChangeNotification = Notification.Name("VolyLocalizationDidChangeNotification")

    private var layoutDirectionMode: LayoutDirectionMode = .system
    private var lastRefresh: LocalizationRefreshResult?
    /// Languages whose strings may currently be on screen: the app's own
    /// resolution plus every override applied this session.
    private var displayedLanguages: Set<String> = []

    public init() {}

    // MARK: - State

    public func state() -> LocalizationState {
        LocalizationState(
            available: Self.availableLanguages(),
            developmentLanguage: Bundle.main.developmentLocalization,
            systemLanguage: Bundle.main.preferredLocalizations.first,
            activeOverride: LocalizationHooks.store.language,
            layoutDirectionMode: layoutDirectionMode,
            isLayoutRightToLeft: Self.appWindows().first?.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            interceptedLookups: LocalizationHooks.intercepted.withLock { $0 },
            lastRefresh: lastRefresh
        )
    }

    private static func availableLanguages() -> [LocalizationLanguage] {
        var codes = Set<String>()
        for bundle in appBundles() {
            codes.formUnion(bundle.localizations.filter { $0 != "Base" })
        }
        let english = Locale(identifier: "en")
        return codes.sorted().map { code in
            LocalizationLanguage(
                code: code,
                displayName: english.localizedString(forIdentifier: code) ?? code,
                isRightToLeft: Locale.Language(identifier: code).characterDirection == .rightToLeft
            )
        }
    }

    /// The main bundle plus frameworks and resource bundles shipped in it.
    private static func appBundles() -> [Bundle] {
        let root = Bundle.main.bundlePath
        return (Bundle.allBundles + Bundle.allFrameworks).filter {
            LocalizationOverrideStore.isInside($0.bundlePath, root: root) && !$0.bundlePath.hasSuffix(".lproj")
        }
    }

    // MARK: - Override

    public func apply(_ request: LocalizationOverrideRequest) throws -> LocalizationState {
        if let language = request.language {
            guard Self.availableLanguages().contains(where: { $0.code == language }) else {
                throw InspectorError.invalidCommand("The app ships no '\(language)' localization.")
            }
            LocalizationHooks.installIfNeeded()
        }
        if displayedLanguages.isEmpty, let system = Bundle.main.preferredLocalizations.first {
            displayedLanguages.insert(system)
        }
        if let previous = LocalizationHooks.store.language { displayedLanguages.insert(previous) }

        LocalizationHooks.store.setLanguage(request.language)
        layoutDirectionMode = request.language == nil ? .system : request.layoutDirectionMode
        applyLayoutDirection()
        log.notice("localization override → \(request.language ?? "none", privacy: .public), layout \(self.layoutDirectionMode.rawValue, privacy: .public)")

        lastRefresh = request.refreshUI ? refreshVisibleUI() : nil
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: request.language.map { ["language": $0] }
        )
        return state()
    }

    public func refresh() -> LocalizationState {
        lastRefresh = refreshVisibleUI()
        return state()
    }

    // MARK: - Layout direction

    /// Language and layout direction are separate axes: the override changes
    /// which strings are returned, this decides whether the UI mirrors.
    private func applyLayoutDirection() {
        let direction: UITraitEnvironmentLayoutDirection?
        switch layoutDirectionMode {
        case .system:
            direction = nil
        case .leftToRight:
            direction = .leftToRight
        case .rightToLeft:
            direction = .rightToLeft
        case .followLanguage:
            direction = LocalizationHooks.store.language.map {
                Locale.Language(identifier: $0).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
            }
        }
        for window in Self.appWindows() {
            if let direction {
                window.traitOverrides.layoutDirection = direction
            } else {
                window.traitOverrides.remove(UITraitLayoutDirection.self)
            }
            window.setNeedsLayout()
        }
    }

    private static func appWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isVolyOverlay && !SelectionHitTest.isSystemWindow($0) }
    }

    // MARK: - Refresh

    private struct Counts {
        var updated = 0
        var unresolved = 0
        var ambiguous = 0
    }

    /// Re-resolve text that provably came from a localization table, in
    /// every loaded screen. Never rebuilds views, never loads a view that
    /// isn't loaded yet, and never writes to editable text.
    private func refreshVisibleUI() -> LocalizationRefreshResult {
        var index = LocalizedStringIndex()
        let bundles = Self.appBundles()
        var bundlesByPath: [String: Bundle] = [:]
        // Index every language that may be on screen, plus the target, so a
        // second refresh is a no-op instead of "unresolved".
        var languages = displayedLanguages
        if let active = LocalizationHooks.store.language { languages.insert(active) }
        if let system = Bundle.main.preferredLocalizations.first { languages.insert(system) }
        for bundle in bundles {
            bundlesByPath[bundle.bundlePath] = bundle
            for language in languages {
                guard let name = LocalizationOverrideStore.bestLocalization(in: bundle.localizations, for: language)
                else { continue }
                for (table, strings) in LocalizedStringIndex.tables(in: bundle, localization: name) {
                    index.add(strings: strings, table: table, bundlePath: bundle.bundlePath)
                }
            }
        }

        var counts = Counts()
        func translate(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            let resolution = index.resolve(text) { entry in
                bundlesByPath[entry.bundlePath]?.localizedString(forKey: entry.key, value: nil, table: entry.table)
            }
            switch resolution {
            case .unknown:
                counts.unresolved += 1
                return nil
            case .ambiguous:
                counts.ambiguous += 1
                return nil
            case .translated(let new):
                guard new != text else { return nil }
                counts.updated += 1
                return new
            }
        }

        var notes: [String] = []
        if index.isEmpty {
            notes.append("No .strings tables found in the app bundle; nothing can be refreshed in place.")
        } else {
            var visited = Set<ObjectIdentifier>()
            for window in Self.appWindows() {
                if let root = window.rootViewController {
                    refresh(controller: root, visited: &visited, translate: translate)
                }
                refresh(view: window, visited: &visited, translate: translate)
                window.setNeedsLayout()
            }
            if counts.unresolved > 0 {
                notes.append("Text built with format arguments, plural rules, or in SwiftUI is not rewritten in place; it updates when its screen is rebuilt.")
            }
        }
        log.notice("localization refresh: \(counts.updated) updated, \(counts.unresolved) unresolved, \(counts.ambiguous) ambiguous")
        return LocalizationRefreshResult(
            updated: counts.updated, unresolved: counts.unresolved, ambiguous: counts.ambiguous, notes: notes
        )
    }

    private func refresh(
        controller: UIViewController,
        visited: inout Set<ObjectIdentifier>,
        translate: (String?) -> String?
    ) {
        // Screens that are loaded but not in the window right now — lower in
        // a navigation stack, another tab, under a sheet — would otherwise
        // come back in the old language.
        if controller.isViewLoaded {
            refresh(view: controller.view, visited: &visited, translate: translate)
        }
        if let new = translate(controller.title) { controller.title = new }
        let item = controller.navigationItem
        if let new = translate(item.title) { item.title = new }
        if let new = translate(item.prompt) { item.prompt = new }
        if let new = translate(item.backButtonTitle) { item.backButtonTitle = new }
        let barItems = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
            + (controller.toolbarItems ?? [])
        for barItem in barItems {
            if let new = translate(barItem.title) { barItem.title = new }
        }
        if controller.parent is UITabBarController, let new = translate(controller.tabBarItem.title) {
            controller.tabBarItem.title = new
        }
        if let search = item.searchController?.searchBar {
            if let new = translate(search.placeholder) { search.placeholder = new }
            if let new = translate(search.prompt) { search.prompt = new }
        }
        for child in controller.children {
            refresh(controller: child, visited: &visited, translate: translate)
        }
        if let presented = controller.presentedViewController, presented.presentingViewController === controller {
            refresh(controller: presented, visited: &visited, translate: translate)
        }
    }

    private func refresh(view: UIView, visited: inout Set<ObjectIdentifier>, translate: (String?) -> String?) {
        guard !view.isVolyOverlay, visited.insert(ObjectIdentifier(view)).inserted else { return }
        switch view {
        case is UINavigationBar, is UITabBar, is UIToolbar:
            // Driven by navigation/tab/bar-button items, handled per controller.
            return
        case let button as UIButton:
            refresh(button: button, translate: translate)
            return
        case let field as UITextField:
            // Placeholder only — `text` is the user's input.
            if let new = translate(field.placeholder) { field.placeholder = new }
            return
        case let segmented as UISegmentedControl:
            for segment in 0..<segmented.numberOfSegments {
                if let new = translate(segmented.titleForSegment(at: segment)) {
                    segmented.setTitle(new, forSegmentAt: segment)
                }
            }
            return
        case let textView as UITextView:
            if !textView.isEditable, Self.hasUniformAttributes(textView.attributedText),
               let new = translate(textView.text) {
                textView.text = new
            }
            return
        case let label as UILabel:
            // Setting `text` keeps label-level styling but would flatten a
            // multi-run attributed string, so those are left alone.
            if Self.hasUniformAttributes(label.attributedText), let new = translate(label.text) {
                label.text = new
            }
            return
        default:
            break
        }
        for subview in view.subviews {
            refresh(view: subview, visited: &visited, translate: translate)
        }
    }

    private func refresh(button: UIButton, translate: (String?) -> String?) {
        if var configuration = button.configuration {
            var changed = false
            if let new = translate(configuration.title) { configuration.title = new; changed = true }
            if let new = translate(configuration.subtitle) { configuration.subtitle = new; changed = true }
            if changed { button.configuration = configuration }
            return
        }
        let normal = button.title(for: .normal)
        if let new = translate(normal) { button.setTitle(new, for: .normal) }
        for state in [UIControl.State.highlighted, .selected, .disabled] {
            // `title(for:)` falls back to the normal title; only rewrite
            // states the app set explicitly.
            let title = button.title(for: state)
            if title != normal, let new = translate(title) { button.setTitle(new, for: state) }
        }
    }

    private static func hasUniformAttributes(_ attributed: NSAttributedString?) -> Bool {
        guard let attributed, attributed.length > 0 else { return true }
        var range = NSRange(location: 0, length: 0)
        _ = attributed.attributes(at: 0, longestEffectiveRange: &range,
                                  in: NSRange(location: 0, length: attributed.length))
        return range.length == attributed.length
    }
}

/// Process-wide hook state. Deliberately not actor-isolated: localized-string
/// lookups arrive on whatever thread the app happens to be on.
private enum LocalizationHooks {
    static let store = LocalizationOverrideStore(appRoot: Bundle.main.bundlePath)
    /// Lookup entry points we replaced; empty until the first override.
    static let intercepted = OSAllocatedUnfairLock(initialState: [String]())
    nonisolated(unsafe) static let missing = "\u{1}voly.missing\u{1}" as NSString

    private typealias Lookup = @convention(c) (Bundle, Selector, NSString?, NSString?, NSString?) -> NSString?
    private typealias LookupWithLocalizations =
        @convention(c) (Bundle, Selector, NSString?, NSString?, NSString?, NSArray?) -> NSString?

    /// Idempotent. Each replacement falls straight through to the original
    /// when there is no override or the bundle isn't the app's.
    static func installIfNeeded() {
        intercepted.withLock { installed in
            guard installed.isEmpty else { return }
            let store = Self.store
            let missing = Self.missing

            let selector = #selector(Bundle.localizedString(forKey:value:table:))
            if let method = class_getInstanceMethod(Bundle.self, selector) {
                let original = unsafeBitCast(method_getImplementation(method), to: Lookup.self)
                let replacement: @convention(block) (Bundle, NSString?, NSString?, NSString?) -> NSString? = {
                    bundle, key, value, table in
                    if key != nil, let lproj = store.overrideBundle(for: bundle) {
                        // Ask the language's own bundle; the sentinel tells a
                        // real translation apart from "key not in this table".
                        let hit = original(lproj, selector, key, missing, table)
                        if let hit, !hit.isEqual(to: missing as String) { return hit }
                    }
                    return original(bundle, selector, key, value, table)
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
                installed.append(NSStringFromSelector(selector))
            }

            // Foundation's newer entry point (String(localized:),
            // LocalizedStringResource) names the localizations to search.
            let listSelector = NSSelectorFromString("localizedStringForKey:value:table:localizations:")
            if let method = class_getInstanceMethod(Bundle.self, listSelector),
               method_getNumberOfArguments(method) == 6 {
                let original = unsafeBitCast(method_getImplementation(method), to: LookupWithLocalizations.self)
                let replacement: @convention(block) (Bundle, NSString?, NSString?, NSString?, NSArray?) -> NSString? = {
                    bundle, key, value, table, localizations in
                    if key != nil, let lproj = store.overrideBundle(for: bundle) {
                        let name = lproj.bundleURL.deletingPathExtension().lastPathComponent
                        let hit = original(bundle, listSelector, key, missing, table, [name] as NSArray)
                        if let hit, !hit.isEqual(to: missing as String) { return hit }
                    }
                    return original(bundle, listSelector, key, value, table, localizations)
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
                installed.append(NSStringFromSelector(listSelector))
            }
        }
    }
}
#endif
