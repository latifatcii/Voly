import XCTest
@testable import VolyAgent

final class LocalizationSupportTests: XCTestCase {
    private var appRoot: URL!

    override func setUp() {
        super.setUp()
        appRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voly-l10n-tests-\(UUID().uuidString)/Sample.app")
        try? FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: appRoot.deletingLastPathComponent())
        super.tearDown()
    }

    /// A minimal bundle on disk with the given `.strings` tables.
    @discardableResult
    private func makeBundle(at url: URL, tables: [String: [String: [String: String]]]) throws -> Bundle {
        for (language, byTable) in tables {
            let lproj = url.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            for (table, strings) in byTable {
                let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
                try data.write(to: lproj.appendingPathComponent("\(table).strings"))
            }
        }
        return try XCTUnwrap(Bundle(url: url))
    }

    // MARK: - bestLocalization

    func test_bestLocalization_prefers_exact_then_base_language() {
        let available = ["Base", "en", "pt", "pt-BR", "zh-Hans", "zh-Hant"]
        XCTAssertEqual(LocalizationOverrideStore.bestLocalization(in: available, for: "pt-BR"), "pt-BR")
        XCTAssertEqual(LocalizationOverrideStore.bestLocalization(in: available, for: "pt_PT"), "pt")
        XCTAssertEqual(LocalizationOverrideStore.bestLocalization(in: available, for: "EN"), "en")
        XCTAssertEqual(LocalizationOverrideStore.bestLocalization(in: ["en", "pt-BR"], for: "pt"), "pt-BR")
    }

    func test_bestLocalization_never_substitutes_an_unrelated_language_or_script() {
        XCTAssertNil(LocalizationOverrideStore.bestLocalization(in: ["en", "fr"], for: "ar"))
        // Simplified vs Traditional are not interchangeable.
        XCTAssertNil(LocalizationOverrideStore.bestLocalization(in: ["zh-Hant"], for: "zh-Hans"))
        XCTAssertNil(LocalizationOverrideStore.bestLocalization(in: ["Base"], for: "Base"))
    }

    // MARK: - override store

    func test_no_override_means_no_redirect() throws {
        let bundle = try makeBundle(at: appRoot, tables: ["fr": ["Localizable": ["k": "v"]]])
        let store = LocalizationOverrideStore(appRoot: appRoot.path)
        XCTAssertNil(store.overrideBundle(for: bundle))
    }

    func test_override_redirects_app_bundles_to_their_lproj() throws {
        let bundle = try makeBundle(at: appRoot, tables: [
            "en": ["Localizable": ["greeting": "Hello"]],
            "fr": ["Localizable": ["greeting": "Bonjour"]],
        ])
        let store = LocalizationOverrideStore(appRoot: appRoot.path)
        store.setLanguage("fr")
        let lproj = try XCTUnwrap(store.overrideBundle(for: bundle))
        XCTAssertEqual(lproj.bundleURL.lastPathComponent, "fr.lproj")
        XCTAssertEqual(lproj.localizedString(forKey: "greeting", value: nil, table: nil), "Bonjour")

        store.setLanguage(nil)
        XCTAssertNil(store.overrideBundle(for: bundle), "clearing the override restores normal lookups")
    }

    func test_override_leaves_bundles_outside_the_app_alone() throws {
        let outside = appRoot.deletingLastPathComponent().appendingPathComponent("System.framework")
        let system = try makeBundle(at: outside, tables: ["fr": ["Localizable": ["k": "v"]]])
        let store = LocalizationOverrideStore(appRoot: appRoot.path)
        store.setLanguage("fr")
        XCTAssertNil(store.overrideBundle(for: system))
        // A sibling whose path merely starts with the app's name isn't "inside" it.
        XCTAssertFalse(LocalizationOverrideStore.isInside(appRoot.path + "Extras/x", root: appRoot.path))
        XCTAssertTrue(LocalizationOverrideStore.isInside(appRoot.path + "/Frameworks/Kit.framework", root: appRoot.path))
    }

    func test_override_skips_a_bundle_without_that_language() throws {
        let framework = appRoot.appendingPathComponent("Frameworks/Kit.framework")
        let kit = try makeBundle(at: framework, tables: ["en": ["Kit": ["k": "v"]]])
        let store = LocalizationOverrideStore(appRoot: appRoot.path)
        store.setLanguage("ar")
        XCTAssertNil(store.overrideBundle(for: kit))
    }

    func test_changing_language_does_not_serve_the_previous_languages_bundle() throws {
        let bundle = try makeBundle(at: appRoot, tables: [
            "fr": ["Localizable": ["k": "fr"]], "ar": ["Localizable": ["k": "ar"]],
        ])
        let store = LocalizationOverrideStore(appRoot: appRoot.path)
        store.setLanguage("fr")
        XCTAssertEqual(store.overrideBundle(for: bundle)?.bundleURL.lastPathComponent, "fr.lproj")
        store.setLanguage("ar")
        XCTAssertEqual(store.overrideBundle(for: bundle)?.bundleURL.lastPathComponent, "ar.lproj")
    }

    // MARK: - reverse index

    func test_tables_reads_every_strings_file_of_one_localization() throws {
        let bundle = try makeBundle(at: appRoot, tables: [
            "en": ["Localizable": ["a": "A"], "Onboarding": ["b": "B"]],
            "fr": ["Localizable": ["a": "Ah"]],
        ])
        let tables = LocalizedStringIndex.tables(in: bundle, localization: "en")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: tables.map { ($0.table, $0.strings) }), [
            "Localizable": ["a": "A"], "Onboarding": ["b": "B"],
        ])
    }

    func test_index_translates_text_that_is_exactly_a_table_value() {
        var index = LocalizedStringIndex()
        index.add(strings: ["title": "Settings"], table: "Localizable", bundlePath: "/app")
        let french = ["title": "Réglages"]
        XCTAssertEqual(index.resolve("Settings") { french[$0.key] }, .translated("Réglages"))
        // Switching back: the index was built from every displayed language.
        index.add(strings: french, table: "Localizable", bundlePath: "/app")
        XCTAssertEqual(index.resolve("Réglages") { _ in "Settings" }, .translated("Settings"))
    }

    func test_index_resolves_an_untranslated_key_shown_verbatim() {
        var index = LocalizedStringIndex()
        index.add(strings: ["Sign In": "Se connecter"], table: "Localizable", bundlePath: "/app")
        XCTAssertEqual(index.resolve("Sign In") { _ in "Se connecter" }, .translated("Se connecter"))
    }

    func test_index_leaves_unknown_text_alone() {
        var index = LocalizedStringIndex()
        index.add(strings: ["items": "You have %d new messages"], table: "Localizable", bundlePath: "/app")
        // Formatted output and user input never equal a table value.
        XCTAssertEqual(index.resolve("You have 3 new messages") { _ in "x" }, .unknown)
        XCTAssertEqual(index.resolve("typed by the user") { _ in "x" }, .unknown)
    }

    func test_index_refuses_to_guess_between_keys_that_translate_differently() {
        var index = LocalizedStringIndex()
        index.add(strings: ["menu.open": "Open", "state.open": "Open"], table: "Localizable", bundlePath: "/app")
        let german = ["menu.open": "Öffnen", "state.open": "Geöffnet"]
        XCTAssertEqual(index.resolve("Open") { german[$0.key] }, .ambiguous)
        // Same translation for every key is not ambiguous.
        XCTAssertEqual(index.resolve("Open") { _ in "Ouvrir" }, .translated("Ouvrir"))
    }
}
