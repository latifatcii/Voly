import Foundation
import VolyModels

/// Finds the source behind a view of an Android app.
///
/// An APK carries no source paths, so unlike on iOS there is nothing to
/// resolve an address with. What the agent reports instead is exact enough
/// to search by: fully qualified class names (a Kotlin or Java file with
/// that name whose `package` line matches), and the view's `android:id`
/// (the layout files, next to those sources, that declare it).
///
/// Kotlin lets a file hold any classes under any name. A class with no
/// file named after it is looked for where its package says it lives, in
/// the modules the other classes were found in, or else in the module
/// whose Gradle file names the app.
public struct AndroidSourceResolver: Sendable {
    public typealias FileSearch = @Sendable (_ fileName: String) async -> [String]

    private let searchFiles: FileSearch
    private let readFile: @Sendable (String) -> String?
    private let listDirectory: @Sendable (String) -> [String]

    public init(
        searchFiles: @escaping FileSearch,
        readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        listDirectory: @escaping @Sendable (String) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
    ) {
        self.searchFiles = searchFiles
        self.readFile = readFile
        self.listDirectory = listDirectory
    }

    public func resolve(_ info: SourceInfo) async -> SourceLookup {
        let candidates = info.candidates ?? []
        var found: [[SourceLocation]] = []
        for candidate in candidates {
            found.append(await locate(candidate))
        }
        // Classes that have no file of their own name.
        if found.contains(where: \.isEmpty), !candidates.isEmpty {
            var modules = Self.unique(found.joined().compactMap { Self.sourceSetsDirectory(of: $0.path) })
            if modules.isEmpty, let application = info.applicationID, !application.isEmpty {
                modules = await modulesBuilding(application)
            }
            for index in candidates.indices where found[index].isEmpty {
                found[index] = declarations(of: candidates[index], inModules: modules)
            }
        }
        var locations = Array(found.joined())
        let sourceFiles = locations.map(\.path)

        // The layout that declares the view's id, in the modules the classes were found in.
        if let resource = info.resourceID, !resource.isEmpty {
            let layouts = layoutLocations(declaring: resource, near: sourceFiles)
            // The view's own class first; a layout says more about a stock widget than its owner does.
            let ownClass = locations.prefix { $0.role == .viewClass || $0.role == .superclass }
            locations = Array(ownClass) + layouts + locations.dropFirst(ownClass.count)
        }

        guard locations.isEmpty else { return SourceLookup(locations: Array(locations.prefix(12)), note: nil) }
        let note: String
        if (info.candidates ?? []).isEmpty {
            note = "\(info.className) is a platform or library class and no app-defined owner was found."
        } else {
            note = "No Kotlin or Java source for "
                + (info.candidates ?? []).map(\.className).joined(separator: ", ")
                + " was found on this Mac (searched with Spotlight by file name, and by the app's Gradle module)."
        }
        return SourceLookup(locations: [], note: note)
    }

    private func locate(_ candidate: SourceCandidate) async -> [SourceLocation] {
        var paths: [String] = []
        for ext in ["kt", "java"] {
            paths += await searchFiles("\(candidate.className).\(ext)")
        }
        let wantedPackage = candidate.moduleName
        return Self.withoutBuildProducts(paths).compactMap { path -> SourceLocation? in
            guard let text = readFile(path) else { return nil }
            // Same file name in another package is another class.
            if let wantedPackage, let declared = Self.package(in: text), declared != wantedPackage { return nil }
            let line = Self.declarationLine(of: candidate.className, in: text)
            return SourceLocation(
                className: candidate.className, moduleName: candidate.moduleName, role: candidate.role,
                path: path, line: line, lineOrigin: line == nil ? .fileOnly : .declaration, method: .spotlight
            )
        }
    }

    /// Files in the package's folder of `modules` (their `src` directories)
    /// that declare the class, whatever they are called.
    private func declarations(of candidate: SourceCandidate, inModules modules: [String]) -> [SourceLocation] {
        guard let package = candidate.moduleName, !package.isEmpty else { return [] }
        let folder = package.replacingOccurrences(of: ".", with: "/")
        var result: [SourceLocation] = []
        for module in modules {
            for sourceSet in listDirectory(module).sorted() {
                for language in ["java", "kotlin"] {
                    let directory = "\(module)/\(sourceSet)/\(language)/\(folder)"
                    for name in listDirectory(directory).sorted() where name.hasSuffix(".kt") || name.hasSuffix(".java") {
                        let path = "\(directory)/\(name)"
                        guard let text = readFile(path), Self.package(in: text) == package,
                              let line = Self.declarationLine(of: candidate.className, in: text)
                        else { continue }
                        result.append(SourceLocation(
                            className: candidate.className, moduleName: candidate.moduleName, role: candidate.role,
                            path: path, line: line, lineOrigin: .declaration, method: .spotlight
                        ))
                    }
                }
            }
        }
        return result
    }

    /// The `src` directories of the Gradle modules that build `application`
    /// (its `applicationId` or `namespace`).
    private func modulesBuilding(_ application: String) async -> [String] {
        var gradleFiles: [String] = []
        for name in ["build.gradle.kts", "build.gradle"] {
            gradleFiles += await searchFiles(name)
        }
        return Self.withoutBuildProducts(gradleFiles).prefix(200).compactMap { path -> String? in
            guard let text = readFile(path), text.contains("\"\(application)\"") || text.contains("'\(application)'")
            else { return nil }
            return (path as NSString).deletingLastPathComponent + "/src"
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// `res/layout*/*.xml` files of the modules holding `sourceFiles` that declare `@+id/<resource>`.
    private func layoutLocations(declaring resource: String, near sourceFiles: [String]) -> [SourceLocation] {
        var seenModules = Set<String>()
        var result: [SourceLocation] = []
        for file in sourceFiles {
            guard let sourceSets = Self.sourceSetsDirectory(of: file), seenModules.insert(sourceSets).inserted else { continue }
            for sourceSet in listDirectory(sourceSets).sorted() {
                let res = "\(sourceSets)/\(sourceSet)/res"
                for folder in listDirectory(res).sorted() where folder.hasPrefix("layout") {
                    for name in listDirectory("\(res)/\(folder)").sorted() where name.hasSuffix(".xml") {
                        let path = "\(res)/\(folder)/\(name)"
                        guard let text = readFile(path), let line = Self.idLine(of: resource, in: text) else { continue }
                        result.append(SourceLocation(
                            className: "\(folder)/\(name) (declares @id/\(resource))", moduleName: nil, role: nil,
                            path: path, line: line, lineOrigin: .declaration, method: .spotlight
                        ))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Pure helpers

    static func withoutBuildProducts(_ paths: [String]) -> [String] {
        let noise = ["/build/", "/.gradle/", "/.idea/", "/node_modules/", "/.Trash/", "/generated/"]
        return Array(Set(paths)).filter { path in !noise.contains { path.contains($0) } }.sorted()
    }

    /// The `package` a Kotlin or Java file declares.
    static func package(in source: String) -> String? {
        for line in source.split(whereSeparator: \.isNewline).prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("package ") else { continue }
            return trimmed.dropFirst("package ".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\t`"))
                .replacingOccurrences(of: "`", with: "")
        }
        return nil
    }

    /// 1-based line of `class Name`, `object Name` or `interface Name`.
    static func declarationLine(of className: String, in source: String) -> Int? {
        let name = NSRegularExpression.escapedPattern(for: className)
        guard let regex = try? NSRegularExpression(pattern: "\\b(?:class|object|interface|enum)\\s+\(name)\\b") else {
            return nil
        }
        for (index, line) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return index + 1 }
        }
        return nil
    }

    /// 1-based line that declares `android:id="@+id/<resource>"`.
    static func idLine(of resource: String, in layout: String) -> Int? {
        let needles = ["@+id/\(resource)\"", "@+id/\(resource)'", "@id/\(resource)\""]
        for (index, line) in layout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
        where line.contains("android:id") && needles.contains(where: { line.contains($0) }) {
            return index + 1
        }
        return nil
    }

    /// `…/app/src/main/java/com/x/Foo.kt` → `…/app/src`, the folder holding the module's source sets.
    static func sourceSetsDirectory(of sourceFile: String) -> String? {
        let parts = sourceFile.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let index = parts.lastIndex(of: "src"), index + 2 < parts.count,
              ["java", "kotlin"].contains(parts[index + 2])
        else { return nil }
        return parts[...index].joined(separator: "/")
    }
}
