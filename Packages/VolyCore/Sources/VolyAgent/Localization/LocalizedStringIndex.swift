#if canImport(UIKit) || os(macOS)
import Foundation

/// Reverse lookup from text currently on screen to the localization key(s)
/// that produce it.
///
/// Built lazily from the app's own `.strings` tables when the user asks for
/// a UI refresh — nothing is recorded on the lookup path. A string is
/// refreshable only if it is exactly a table value (or an untranslated key);
/// formatted, pluralised and hard-coded text has no entry and is left alone.
struct LocalizedStringIndex {
    struct Entry: Hashable {
        let bundlePath: String
        let table: String
        let key: String
    }

    private var entriesByText: [String: Set<Entry>] = [:]

    var isEmpty: Bool { entriesByText.isEmpty }

    mutating func add(strings: [String: String], table: String, bundlePath: String) {
        for (key, value) in strings {
            let entry = Entry(bundlePath: bundlePath, table: table, key: key)
            entriesByText[value, default: []].insert(entry)
            // An untranslated key is displayed verbatim.
            entriesByText[key, default: []].insert(entry)
        }
    }

    func entries(displaying text: String) -> Set<Entry> {
        entriesByText[text] ?? []
    }

    /// Reads every `.strings` table a bundle ships for one localization.
    /// `.stringsdict` (plural/variable rules) is deliberately not indexed:
    /// its output depends on runtime arguments and can't be reversed.
    static func tables(in bundle: Bundle, localization: String) -> [(table: String, strings: [String: String])] {
        guard let urls = bundle.urls(forResourcesWithExtension: "strings", subdirectory: nil, localization: localization)
        else { return [] }
        return urls.compactMap { url in
            guard let raw = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
            let strings = raw.compactMapValues { $0 as? String }
            guard !strings.isEmpty else { return nil }
            return (url.deletingPathExtension().lastPathComponent, strings)
        }
    }

    enum Resolution: Equatable {
        /// No table produces this text.
        case unknown
        /// Several keys produce it and they translate differently.
        case ambiguous
        case translated(String)
    }

    /// Decide the replacement for `text`, given how each matching key
    /// resolves under the now-active language.
    func resolve(_ text: String, lookup: (Entry) -> String?) -> Resolution {
        let matches = entries(displaying: text)
        guard !matches.isEmpty else { return .unknown }
        let translations = Set(matches.compactMap(lookup))
        guard let only = translations.first else { return .unknown }
        return translations.count == 1 ? .translated(only) : .ambiguous
    }
}
#endif
