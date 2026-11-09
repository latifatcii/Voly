import Foundation
import OSLog
import VolyModels

private let log = Logger(subsystem: "com.latifatci.Voly", category: "SourceNavigator")

/// A place in the local checkout worth opening for the selected view.
public struct SourceLocation: Equatable, Sendable, Identifiable {
    /// Where the line number came from — shown to the user so a jump is
    /// never presented as more exact than it is.
    public enum LineOrigin: Equatable, Sendable {
        /// The type's declaration, found in the file debug info pointed at.
        case declaration
        /// First line of this method, straight from the line table.
        case method(String)
        /// The file is known but no line could be established.
        case fileOnly
    }

    public enum Method: Equatable, Sendable {
        /// File (and line) come from the binary's debug info.
        case debugInfo
        /// File found by name through Spotlight; no debug info involved.
        case spotlight
    }

    public let className: String
    public let moduleName: String?
    public let role: SourceCandidate.Role?
    public let path: String
    public let line: Int?
    public let lineOrigin: LineOrigin
    public let method: Method

    public var id: String { "\(path):\(line ?? 0):\(className)" }
    public var fileName: String { (path as NSString).lastPathComponent }

    public init(
        className: String, moduleName: String?, role: SourceCandidate.Role?,
        path: String, line: Int?, lineOrigin: LineOrigin, method: Method
    ) {
        self.className = className
        self.moduleName = moduleName
        self.role = role
        self.path = path
        self.line = line
        self.lineOrigin = lineOrigin
        self.method = method
    }
}

public struct SourceLookup: Equatable, Sendable {
    /// Best first: the selection's own class, then app-defined owners.
    public let locations: [SourceLocation]
    /// Why an exact (debug-info) answer wasn't possible, when it wasn't.
    public let note: String?

    public init(locations: [SourceLocation], note: String?) {
        self.locations = locations
        self.note = note
    }

    /// The best match is one of several files for the same class, so opening
    /// it without asking could land in the wrong checkout. Locations for
    /// *other* classes (owners further up) are alternatives, not ambiguity.
    public var isAmbiguous: Bool {
        guard let best = locations.first else { return false }
        return locations.filter { $0.className == best.className && $0.role == best.role }.count > 1
    }
}

/// Resolves a selection to source: debug info first (file + line), then the
/// file alone, then a Spotlight search by class name.
public struct VolySourceNavigator: Sendable {
    public typealias FileSearch = @Sendable (_ fileName: String) async -> [String]

    private let symbolicator: Symbolicating
    private let shell: ShellExecutor
    private let fileExists: @Sendable (String) -> Bool
    private let readFile: @Sendable (String) -> String?
    private let searchFiles: FileSearch

    public init(
        symbolicator: Symbolicating = LLDBSymbolicator(),
        shell: ShellExecutor = SystemShellExecutor(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        searchFiles: FileSearch? = nil
    ) {
        self.symbolicator = symbolicator
        self.shell = shell
        self.fileExists = fileExists
        self.readFile = readFile
        self.searchFiles = searchFiles ?? { name in await Self.spotlightSearch(fileName: name, shell: shell) }
    }

    // MARK: - Resolve

    public func resolve(_ info: SourceInfo) async -> SourceLookup {
        let candidates = info.candidates ?? []
        guard !candidates.isEmpty else {
            // Nothing app-defined on or around the selection.
            let found = await spotlightLocations(className: info.className, moduleName: info.moduleName, role: nil)
            return SourceLookup(
                locations: found,
                note: found.isEmpty
                    ? "\(info.className) belongs to a system framework and no app-defined owner was found."
                    : "\(info.className) has no app-defined class in the running binary; matched by file name."
            )
        }

        var requests: [String: [UInt64]] = [:]
        for candidate in candidates {
            requests[candidate.imagePath, default: []].append(contentsOf: candidate.probes.map(\.imageOffset))
        }
        var images: [String: SymbolicatedImage] = [:]
        var symbolicationFailure: String?
        do {
            for image in try await symbolicator.symbolicate(requests) { images[image.path] = image }
        } catch {
            symbolicationFailure = error.localizedDescription
            log.error("symbolication failed: \(String(describing: error), privacy: .public)")
        }

        var locations: [SourceLocation] = []
        var primaryNote: String?
        var ownerNotes: [String] = []
        for (index, candidate) in candidates.enumerated() {
            let outcome = await locate(candidate, in: images[candidate.imagePath])
            locations.append(contentsOf: outcome.locations)
            guard let note = outcome.note else { continue }
            if index == 0 { primaryNote = note } else { ownerNotes.append(note) }
        }
        if let symbolicationFailure, locations.allSatisfy({ $0.method == .spotlight }) {
            return SourceLookup(locations: locations, note: "Debug info lookup failed: \(symbolicationFailure)")
        }
        // Caveats about the best answer always show. Trouble resolving an
        // owner further up only matters when nothing better was found.
        return SourceLookup(locations: locations, note: primaryNote ?? (locations.isEmpty ? ownerNotes.first : nil))
    }

    private func locate(
        _ candidate: SourceCandidate,
        in image: SymbolicatedImage?
    ) async -> (locations: [SourceLocation], note: String?) {
        let hits = (image?.probes ?? []).filter { probe in
            guard let file = probe.file, probe.line != nil else { return false }
            return candidate.probes.contains { $0.imageOffset == probe.offset } && !file.hasSuffix("<compiler-generated>")
        }

        guard let recordedFile = Self.dominantFile(in: hits) else {
            let reason: String
            if let error = image?.error {
                reason = "Could not open \((candidate.imagePath as NSString).lastPathComponent): \(error)"
            } else if image?.compileUnits == 0 {
                reason = "Debug symbols are unavailable for \(candidate.className) (no DWARF or dSYM for its binary)."
            } else {
                reason = "Debug info has no line entries for \(candidate.className)."
            }
            let found = await spotlightLocations(
                className: candidate.className, moduleName: candidate.moduleName, role: candidate.role
            )
            return (found, found.isEmpty ? reason : reason + " Matched by file name instead.")
        }

        // Debug info records the path at build time; the checkout may have
        // moved, or the binary may have been built on another machine.
        let localPaths: [String]
        var note: String?
        if fileExists(recordedFile) {
            localPaths = [recordedFile]
        } else {
            let matches = Self.rank(await searchFiles((recordedFile as NSString).lastPathComponent), against: recordedFile)
            localPaths = matches
            note = matches.isEmpty
                ? "Source path no longer exists: \(recordedFile)"
                : matches.count > 1
                    ? "Source path \(recordedFile) no longer exists; multiple candidates were found."
                    : "Source path \(recordedFile) no longer exists; using \(matches[0])."
        }

        let fileHits = hits.filter { $0.file == recordedFile }
        let locations = localPaths.map { path -> SourceLocation in
            let (line, origin) = bestLine(for: candidate.className, in: path, hits: fileHits)
            return SourceLocation(
                className: candidate.className, moduleName: candidate.moduleName, role: candidate.role,
                path: path, line: line, lineOrigin: origin, method: .debugInfo
            )
        }
        return (locations, note)
    }

    /// Prefer the type's declaration — the debug info told us which file, the
    /// file itself tells us where the declaration is. Otherwise the first
    /// line of a method the line table knows about. Never a made-up number.
    private func bestLine(
        for className: String,
        in path: String,
        hits: [SymbolicatedProbe]
    ) -> (Int?, SourceLocation.LineOrigin) {
        if let text = readFile(path), let line = Self.declarationLine(of: className, in: text) {
            return (line, .declaration)
        }
        let ranked = hits.sorted { lhs, rhs in
            let l = Self.methodRank(lhs.symbol), r = Self.methodRank(rhs.symbol)
            return l != r ? l < r : (lhs.line ?? .max) < (rhs.line ?? .max)
        }
        if let best = ranked.first, let line = best.line {
            return (line, .method(Self.shortName(of: best.symbol)))
        }
        return (nil, .fileOnly)
    }

    private func spotlightLocations(
        className: String,
        moduleName: String?,
        role: SourceCandidate.Role?
    ) async -> [SourceLocation] {
        let bare = Self.bareTypeName(className)
        var paths: [String] = []
        for ext in ["swift", "m", "mm"] {
            paths.append(contentsOf: await searchFiles("\(bare).\(ext)"))
        }
        return Self.rank(paths, against: nil).prefix(8).map { path in
            let line = readFile(path).flatMap { Self.declarationLine(of: bare, in: $0) }
            return SourceLocation(
                className: className, moduleName: moduleName, role: role,
                path: path, line: line, lineOrigin: line == nil ? .fileOnly : .declaration, method: .spotlight
            )
        }
    }

    // MARK: - Open

    /// Open in Xcode, at `line` when there is one.
    public func open(_ location: SourceLocation) async throws {
        var arguments: [String] = []
        if let line = location.line { arguments += ["--line", String(line)] }
        arguments.append(location.path)
        let result = try await shell.run(
            executable: URL(fileURLWithPath: "/usr/bin/xed"), arguments: arguments, environment: nil
        )
        guard result.exitCode == 0 else {
            throw NSError(domain: "VolySourceNavigator", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "xed could not open \(location.path): "
                    + (String(data: result.stderr, encoding: .utf8) ?? ""),
            ])
        }
    }

    // MARK: - Pure helpers

    /// The file most of a class's methods live in (extensions in other files
    /// are the minority).
    static func dominantFile(in hits: [SymbolicatedProbe]) -> String? {
        var counts: [String: Int] = [:]
        for hit in hits { if let file = hit.file { counts[file, default: 0] += 1 } }
        return counts.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key
    }

    /// `Foo<Bar>` → `Foo`; nested `Outer.Inner` → `Inner`.
    static func bareTypeName(_ name: String) -> String {
        let generic = name.split(separator: "<").first.map(String.init) ?? name
        return generic.split(separator: ".").last.map(String.init) ?? generic
    }

    /// 1-based line of the type's declaration in `source`, for Swift
    /// (`class`/`actor`/`struct`/`enum`) and Objective-C (`@implementation`,
    /// falling back to `@interface`). Extensions are not declarations.
    static func declarationLine(of className: String, in source: String) -> Int? {
        let name = NSRegularExpression.escapedPattern(for: bareTypeName(className))
        let patterns = [
            "^[^/\\n]*\\b(?:class|actor|struct|enum)\\s+\(name)\\b(?!\\s*\\.)",
            "^\\s*@implementation\\s+\(name)\\b(?!\\s*\\()",
            "^\\s*@interface\\s+\(name)\\b(?!\\s*\\()",
        ]
        let whole = NSRange(source.startIndex..., in: source)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                  let match = regex.firstMatch(in: source, range: whole),
                  let range = Range(match.range, in: source)
            else { continue }
            return source[..<range.lowerBound].reduce(into: 1) { count, character in
                if character.isNewline { count += 1 }
            }
        }
        return nil
    }

    private static func methodRank(_ symbol: String?) -> Int {
        guard let symbol else { return 9 }
        if symbol.contains("init(") || symbol.contains(" init") { return 0 }
        if symbol.contains("viewDidLoad") || symbol.contains("loadView") || symbol.contains("awakeFromNib") { return 1 }
        if symbol.contains("deinit") || symbol.contains("cxx_destruct") { return 8 }
        return 2
    }

    /// `Module.Type.method(arg:) -> Result` → `method(arg:)`; ObjC stays as is.
    static func shortName(of symbol: String?) -> String {
        guard let symbol else { return "method" }
        if symbol.hasPrefix("-[") || symbol.hasPrefix("+[") { return symbol }
        let signature = symbol.components(separatedBy: " -> ").first ?? symbol
        guard let paren = signature.firstIndex(of: "(") else {
            return signature.split(separator: ".").last.map(String.init) ?? signature
        }
        let head = signature[..<paren]
        let name = head.split(separator: ".").last.map(String.init) ?? String(head)
        let labels = signature[paren...]
            .dropFirst().dropLast()
            .split(separator: ",")
            .compactMap { $0.split(separator: ":").first?.trimmingCharacters(in: .whitespaces) }
            .map { "\($0):" }
            .joined()
        return "\(name)(\(labels))"
    }

    /// Drop build products and vendored copies, then order by how much of
    /// the recorded path each candidate shares (deepest common suffix wins).
    static func rank(_ paths: [String], against recorded: String?) -> [String] {
        let noise = ["/DerivedData/", "/.build/", "/build/", "/Pods/", "/node_modules/", "/SourcePackages/", "/.Trash/"]
        let unique = Array(Set(paths)).filter { path in !noise.contains { path.contains($0) } }
        guard let recorded else { return unique.sorted() }
        let wanted = Array(recorded.split(separator: "/").reversed())
        func score(_ path: String) -> Int {
            var shared = 0
            for (lhs, rhs) in zip(path.split(separator: "/").reversed(), wanted) {
                if lhs != rhs { break }
                shared += 1
            }
            return shared
        }
        let scored = unique.map { ($0, score($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        guard let best = scored.first?.1 else { return [] }
        // Only the best-matching tier is worth showing.
        return scored.filter { $0.1 == best }.map(\.0)
    }

    static func spotlightSearch(fileName: String, shell: ShellExecutor) async -> [String] {
        guard let result = try? await shell.run(
            executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: ["-name", fileName],
            environment: nil
        ), result.exitCode == 0 else { return [] }
        return (String(data: result.stdout, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { ($0 as NSString).lastPathComponent == fileName }
    }
}
