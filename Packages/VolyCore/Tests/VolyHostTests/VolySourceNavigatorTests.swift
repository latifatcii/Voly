import XCTest
import VolyModels
@testable import VolyHost

final class VolySourceNavigatorTests: XCTestCase {
    struct FakeSymbolicator: Symbolicating {
        var images: [SymbolicatedImage] = []
        var error: Error?
        func symbolicate(_ requests: [String: [UInt64]]) async throws -> [SymbolicatedImage] {
            if let error { throw error }
            return images
        }
    }

    final class NoShell: ShellExecutor {
        func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
            ShellResult(exitCode: 1, stdout: Data(), stderr: Data())
        }
    }

    private let image = "/sim/App.app/App.debug.dylib"
    private let badgeFile = "/Users/dev/App/Sources/BadgeView.swift"
    private let badgeSource = """
    import UIKit

    // class BadgeView is declared below
    extension BadgeView: Tappable {}

    final class BadgeView: UIView {
        override init(frame: CGRect) { super.init(frame: frame) }
        override func layoutSubviews() {}
    }
    """

    private func candidate(
        _ name: String,
        role: SourceCandidate.Role = .viewClass,
        offsets: [UInt64] = [0x10, 0x20]
    ) -> SourceCandidate {
        SourceCandidate(
            role: role, className: name, moduleName: "App", runtimeName: "App.\(name)",
            imagePath: image, imageUUID: "UUID",
            probes: offsets.enumerated().map { .init(selector: "sel\($0.offset)", imageOffset: $0.element) }
        )
    }

    private func info(_ candidates: [SourceCandidate], className: String = "BadgeView") -> SourceInfo {
        SourceInfo(className: className, moduleName: "App", dsymUUID: nil, guessedRelativePath: nil, candidates: candidates)
    }

    private func navigator(
        images: [SymbolicatedImage] = [],
        error: Error? = nil,
        files: [String: String] = [:],
        search: [String: [String]] = [:]
    ) -> VolySourceNavigator {
        VolySourceNavigator(
            symbolicator: FakeSymbolicator(images: images, error: error),
            shell: NoShell(),
            fileExists: { files[$0] != nil },
            readFile: { files[$0] },
            searchFiles: { search[$0] ?? [] }
        )
    }

    private func symbolicated(_ probes: [SymbolicatedProbe], compileUnits: Int = 3) -> SymbolicatedImage {
        SymbolicatedImage(path: image, uuid: "UUID", compileUnits: compileUnits, error: nil, probes: probes)
    }

    // MARK: - resolve

    func test_debug_info_file_plus_declaration_line_from_that_file() async {
        let subject = navigator(
            images: [symbolicated([
                .init(offset: 0x10, symbol: "App.BadgeView.init(frame: __C.CGRect) -> App.BadgeView", file: badgeFile, line: 7),
                .init(offset: 0x20, symbol: "App.BadgeView.layoutSubviews() -> ()", file: badgeFile, line: 8),
            ])],
            files: [badgeFile: badgeSource]
        )
        let lookup = await subject.resolve(info([candidate("BadgeView")]))

        XCTAssertEqual(lookup.locations, [SourceLocation(
            className: "BadgeView", moduleName: "App", role: .viewClass,
            path: badgeFile, line: 6, lineOrigin: .declaration, method: .debugInfo
        )])
        XCTAssertNil(lookup.note)
        XCTAssertFalse(lookup.isAmbiguous)
    }

    func test_falls_back_to_a_line_table_entry_when_the_declaration_is_not_in_the_file() async {
        // e.g. an Objective-C class whose methods live in a category file.
        let subject = navigator(
            images: [symbolicated([
                .init(offset: 0x10, symbol: "App.BadgeView.layoutSubviews() -> ()", file: badgeFile, line: 40),
                .init(offset: 0x20, symbol: "App.BadgeView.init(frame: __C.CGRect) -> App.BadgeView", file: badgeFile, line: 55),
            ])],
            files: [badgeFile: "// nothing that declares the type\n"]
        )
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        // The initializer is preferred over an arbitrary method, and the
        // origin says exactly what the number is.
        XCTAssertEqual(lookup.locations.first?.line, 55)
        XCTAssertEqual(lookup.locations.first?.lineOrigin, .method("init(frame:)"))
    }

    func test_compiler_generated_rows_are_not_source_locations() async {
        let subject = navigator(
            images: [symbolicated([
                .init(offset: 0x10, symbol: "@objc App.BadgeView.init(coder:)", file: "/<compiler-generated>", line: 1),
                .init(offset: 0x20, symbol: "App.BadgeView.layoutSubviews() -> ()", file: badgeFile, line: 8),
            ])],
            files: [badgeFile: badgeSource]
        )
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        XCTAssertEqual(lookup.locations.map(\.path), [badgeFile])
    }

    func test_moved_checkout_is_found_by_name_and_ranked_by_shared_path() async {
        let moved = "/Users/me/Work/App/Sources/BadgeView.swift"
        let unrelated = "/Users/me/Other/BadgeView.swift"
        let subject = navigator(
            images: [symbolicated([.init(offset: 0x10, symbol: "App.BadgeView.layoutSubviews() -> ()", file: badgeFile, line: 8)])],
            files: [moved: badgeSource, unrelated: badgeSource],
            search: ["BadgeView.swift": [unrelated, moved, "/Users/me/Work/App/DerivedData/x/BadgeView.swift"]]
        )
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        XCTAssertEqual(lookup.locations.map(\.path), [moved])
        XCTAssertEqual(lookup.locations.first?.line, 6)
        XCTAssertEqual(lookup.locations.first?.method, .debugInfo)
        XCTAssertEqual(lookup.note, "Source path \(badgeFile) no longer exists; using \(moved).")
    }

    func test_several_equally_good_checkouts_are_reported_as_ambiguous() async {
        let a = "/Users/me/A/Sources/BadgeView.swift", b = "/Users/me/B/Sources/BadgeView.swift"
        let subject = navigator(
            images: [symbolicated([.init(offset: 0x10, symbol: "App.BadgeView.layoutSubviews() -> ()", file: badgeFile, line: 8)])],
            files: [a: badgeSource, b: badgeSource],
            search: ["BadgeView.swift": [a, b]]
        )
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        XCTAssertEqual(Set(lookup.locations.map(\.path)), [a, b])
        XCTAssertTrue(lookup.isAmbiguous)
        XCTAssertEqual(lookup.note, "Source path \(badgeFile) no longer exists; multiple candidates were found.")
    }

    func test_missing_source_is_reported_with_the_recorded_path() async {
        let subject = navigator(
            images: [symbolicated([.init(offset: 0x10, symbol: "App.BadgeView.layoutSubviews() -> ()", file: badgeFile, line: 8)])]
        )
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        XCTAssertTrue(lookup.locations.isEmpty)
        XCTAssertEqual(lookup.note, "Source path no longer exists: \(badgeFile)")
    }

    func test_no_debug_info_falls_back_to_file_name_search() async {
        let found = "/Users/me/App/BadgeView.swift"
        let subject = navigator(
            images: [symbolicated([.init(offset: 0x10, symbol: "App.BadgeView.layoutSubviews() -> ()", file: nil, line: nil)], compileUnits: 0)],
            files: [found: badgeSource],
            search: ["BadgeView.swift": [found]]
        )
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        XCTAssertEqual(lookup.locations.map(\.method), [.spotlight])
        XCTAssertEqual(lookup.locations.first?.line, 6)
        XCTAssertEqual(
            lookup.note,
            "Debug symbols are unavailable for BadgeView (no DWARF or dSYM for its binary). Matched by file name instead."
        )
    }

    func test_no_debug_info_and_no_file_gives_a_clear_reason() async {
        let subject = navigator(images: [symbolicated([], compileUnits: 0)])
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        XCTAssertTrue(lookup.locations.isEmpty)
        XCTAssertEqual(lookup.note, "Debug symbols are unavailable for BadgeView (no DWARF or dSYM for its binary).")
    }

    func test_system_view_without_app_owner_says_so() async {
        let lookup = await navigator().resolve(info([], className: "UILabel"))
        XCTAssertTrue(lookup.locations.isEmpty)
        XCTAssertEqual(lookup.note, "UILabel belongs to a system framework and no app-defined owner was found.")
    }

    func test_owner_candidates_follow_the_selection_and_are_not_ambiguity() async {
        let controllerFile = "/Users/dev/App/Sources/HomeVC.swift"
        let subject = navigator(
            images: [symbolicated([
                .init(offset: 0x10, symbol: "App.BadgeView.layoutSubviews() -> ()", file: badgeFile, line: 8),
                .init(offset: 0x30, symbol: "App.HomeVC.viewDidLoad() -> ()", file: controllerFile, line: 12),
            ])],
            files: [badgeFile: badgeSource, controllerFile: "import UIKit\nclass HomeVC: UIViewController {\n}\n"]
        )
        let lookup = await subject.resolve(info([
            candidate("BadgeView", offsets: [0x10]),
            candidate("HomeVC", role: .viewController, offsets: [0x30]),
        ]))
        XCTAssertEqual(lookup.locations.map(\.className), ["BadgeView", "HomeVC"])
        XCTAssertEqual(lookup.locations.map(\.line), [6, 2])
        XCTAssertFalse(lookup.isAmbiguous)
    }

    func test_symbolicator_failure_still_tries_the_file_name() async {
        struct Boom: LocalizedError { var errorDescription: String? { "lldb is not installed" } }
        let found = "/Users/me/App/BadgeView.swift"
        let subject = navigator(error: Boom(), files: [found: badgeSource], search: ["BadgeView.swift": [found]])
        let lookup = await subject.resolve(info([candidate("BadgeView")]))
        XCTAssertEqual(lookup.locations.map(\.path), [found])
        XCTAssertEqual(lookup.note, "Debug info lookup failed: lldb is not installed")
    }

    // MARK: - helpers

    func test_declarationLine_swift_and_objc() {
        XCTAssertEqual(VolySourceNavigator.declarationLine(of: "BadgeView", in: badgeSource), 6)
        XCTAssertEqual(VolySourceNavigator.declarationLine(of: "Outer.Inner", in: "struct Outer {\n    final class Inner {}\n}"), 2)
        XCTAssertEqual(VolySourceNavigator.declarationLine(of: "Cell<Item>", in: "open class Cell<Item>: UIView {}"), 1)
        let objc = "#import \"Foo.h\"\n@interface Foo ()\n@end\n\n@implementation Foo (Extras)\n@end\n@implementation Foo\n@end\n"
        XCTAssertEqual(VolySourceNavigator.declarationLine(of: "Foo", in: objc), 7)
        XCTAssertNil(VolySourceNavigator.declarationLine(of: "Badge", in: badgeSource), "must match the whole name")
        XCTAssertNil(VolySourceNavigator.declarationLine(of: "BadgeView", in: "extension BadgeView {}\n"))
    }

    func test_shortName() {
        XCTAssertEqual(VolySourceNavigator.shortName(of: "App.BadgeView.init(frame: __C.CGRect) -> App.BadgeView"), "init(frame:)")
        XCTAssertEqual(VolySourceNavigator.shortName(of: "App.HomeVC.viewDidLoad() -> ()"), "viewDidLoad()")
        XCTAssertEqual(VolySourceNavigator.shortName(of: "-[Foo layoutSubviews]"), "-[Foo layoutSubviews]")
        XCTAssertEqual(VolySourceNavigator.shortName(of: nil), "method")
    }

    func test_dominantFile_prefers_where_most_methods_live() {
        let hits: [SymbolicatedProbe] = [
            .init(offset: 1, symbol: nil, file: "/a/Main.swift", line: 1),
            .init(offset: 2, symbol: nil, file: "/a/Main.swift", line: 2),
            .init(offset: 3, symbol: nil, file: "/a/Main+Extras.swift", line: 3),
        ]
        XCTAssertEqual(VolySourceNavigator.dominantFile(in: hits), "/a/Main.swift")
        XCTAssertNil(VolySourceNavigator.dominantFile(in: []))
    }

    func test_open_passes_the_line_to_xed() async throws {
        final class Recorder: ShellExecutor, @unchecked Sendable {
            var calls: [(String, [String])] = []
            func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
                calls.append((executable.path, arguments))
                return ShellResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        }
        let shell = Recorder()
        let subject = VolySourceNavigator(symbolicator: FakeSymbolicator(), shell: shell)
        try await subject.open(SourceLocation(
            className: "A", moduleName: nil, role: nil, path: "/x/A.swift", line: 42, lineOrigin: .declaration, method: .debugInfo
        ))
        try await subject.open(SourceLocation(
            className: "A", moduleName: nil, role: nil, path: "/x/A.swift", line: nil, lineOrigin: .fileOnly, method: .spotlight
        ))
        XCTAssertEqual(shell.calls.map(\.0), ["/usr/bin/xed", "/usr/bin/xed"])
        XCTAssertEqual(shell.calls.map(\.1), [["--line", "42", "/x/A.swift"], ["/x/A.swift"]])
    }
}

final class LLDBSymbolicatorTests: XCTestCase {
    func test_parse_reads_the_json_between_the_markers() throws {
        let output = """
        (lldb) command script import "/tmp/voly_source_lookup.py"
        (lldb) voly_source_lookup "/tmp/request.json"
        <<<VOLY_SOURCE_JSON
        {"images": [{"path": "/sim/App.debug.dylib", "uuid": "6DB5", "compileUnits": 41, "error": null,
          "probes": [{"offset": 245172, "symbol": "App.BadgeView.init(frame:)", "file": "/src/BadgeView.swift", "line": 38},
                     {"offset": 12, "symbol": null, "file": null, "line": null}]}]}
        VOLY_SOURCE_JSON>>>
        """
        let images = try LLDBSymbolicator.parse(output: output)
        XCTAssertEqual(images, [SymbolicatedImage(
            path: "/sim/App.debug.dylib", uuid: "6DB5", compileUnits: 41, error: nil,
            probes: [
                .init(offset: 245172, symbol: "App.BadgeView.init(frame:)", file: "/src/BadgeView.swift", line: 38),
                .init(offset: 12, symbol: nil, file: nil, line: nil),
            ]
        )])
    }

    func test_parse_rejects_output_without_a_result() {
        XCTAssertThrowsError(try LLDBSymbolicator.parse(output: "error: no such command")) { error in
            XCTAssertEqual(error as? LLDBSymbolicator.SymbolicationError, .malformedOutput)
        }
    }

    func test_symbolicate_runs_lldb_in_batch_mode_without_attaching() async throws {
        final class Recorder: ShellExecutor, @unchecked Sendable {
            var arguments: [String] = []
            func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
                self.arguments = arguments
                let out = "<<<VOLY_SOURCE_JSON\n{\"images\": []}\nVOLY_SOURCE_JSON>>>\n"
                return ShellResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data())
            }
        }
        let shell = Recorder()
        _ = try await LLDBSymbolicator(shell: shell).symbolicate(["/sim/App": [1, 2]])
        XCTAssertEqual(Array(shell.arguments.prefix(3)), ["lldb", "--batch", "--no-lldbinit"])
        // Static lookups only: nothing here may attach to or launch a process.
        let script = shell.arguments.joined(separator: " ") + LLDBSymbolicator.script
        for forbidden in ["process attach", "AttachToProcess", "-p ", "process launch", ".Launch("] {
            XCTAssertFalse(script.contains(forbidden), "lldb script must not use \(forbidden)")
        }
    }
}
