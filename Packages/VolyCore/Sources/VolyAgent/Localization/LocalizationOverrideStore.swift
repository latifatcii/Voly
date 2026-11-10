#if canImport(UIKit) || os(macOS)
import Foundation
import os

/// Thread-safe state behind the localization hook: the active override
/// language and a cache of which `.lproj` to consult per bundle.
///
/// Localized-string lookups happen on arbitrary threads and can be hot, so
/// the no-override path is a single lock + nil check and nothing is cached or
/// scanned until an override is actually set.
final class LocalizationOverrideStore: Sendable {
    private struct State {
        var language: String?
        var appRoot: String
        /// bundlePath → resolved `.lproj` bundle for `language`
        /// (`.some(nil)` = looked, this bundle has no usable match).
        var lprojByBundlePath: [String: Bundle?] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    /// - Parameter appRoot: only bundles inside this directory are
    ///   overridden, so system frameworks keep the device language.
    init(appRoot: String) {
        state = OSAllocatedUnfairLock(uncheckedState: State(language: nil, appRoot: appRoot))
    }

    var language: String? {
        state.withLockUnchecked { $0.language }
    }

    func setLanguage(_ language: String?) {
        state.withLockUnchecked {
            $0.language = language
            $0.lprojByBundlePath.removeAll(keepingCapacity: true)
        }
    }

    /// The `.lproj` sub-bundle to read from for `bundle` under the current
    /// override, or nil when there is no override, the bundle isn't part of
    /// the app, or it ships no matching localization.
    func overrideBundle(for bundle: Bundle) -> Bundle? {
        let path = bundle.bundlePath
        return state.withLockUnchecked { state -> Bundle? in
            guard let language = state.language else { return nil }
            if let cached = state.lprojByBundlePath[path] { return cached }
            let resolved = Self.resolve(bundle: bundle, path: path, language: language, appRoot: state.appRoot)
            state.lprojByBundlePath[path] = .some(resolved)
            return resolved
        }
    }

    private static func resolve(bundle: Bundle, path: String, language: String, appRoot: String) -> Bundle? {
        guard isInside(path, root: appRoot) else { return nil }
        // An `.lproj` directory is itself a valid bundle; asking it for
        // `<lang>.lproj` again would recurse.
        guard !path.hasSuffix(".lproj") else { return nil }
        guard let name = bestLocalization(in: bundle.localizations, for: language),
              let lprojPath = bundle.path(forResource: name, ofType: "lproj")
        else { return nil }
        return Bundle(path: lprojPath)
    }

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Pick the localization a bundle should use for `language`, without
    /// falling back to an unrelated language: exact match, then the bare
    /// language code (`pt-BR` → `pt`), then a regional variant of it
    /// (`pt` → `pt-BR`). Returns nil when the bundle has none of those, which
    /// leaves that bundle on the app's normal behaviour.
    static func bestLocalization(in available: [String], for language: String) -> String? {
        let candidates = available.filter { $0 != "Base" }
        func normalized(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "-").lowercased() }
        let wanted = normalized(language)
        if let exact = candidates.first(where: { normalized($0) == wanted }) { return exact }
        let wantedBase = wanted.split(separator: "-").first.map(String.init) ?? wanted
        if let base = candidates.first(where: { normalized($0) == wantedBase }) { return base }
        // Script subtags matter (zh-Hans vs zh-Hant), so only accept a
        // regional variant when the request itself was a bare language.
        if wanted == wantedBase,
           let variant = candidates.first(where: { normalized($0).hasPrefix(wantedBase + "-") }) {
            return variant
        }
        return nil
    }
}
#endif
