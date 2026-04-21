import Foundation
import AppKit

@MainActor
@Observable
final class SourceNavigation {
    static let shared = SourceNavigation()

    var workspaceRoot: URL? {
        get {
            if let path = UserDefaults.standard.string(forKey: Self.rootKey) {
                return URL(fileURLWithPath: path)
            }
            return nil
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: Self.rootKey)
        }
    }

    private static let rootKey = "voly.workspaceRoot"

    /// Attempts to find `<name>` under the configured workspace root using `mdfind`.
    /// Returns the first match, or nil if none found.
    func findFile(named name: String) async -> URL? {
        guard let root = workspaceRoot else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-onlyin", root.path, "kMDItemFSName == '\(name)'"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let lines = output.split(separator: "\n")
                    guard let first = lines.first else { cont.resume(returning: nil); return }
                    cont.resume(returning: URL(fileURLWithPath: String(first)))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

enum XcodeLauncher {
    static func open(url: URL, line: Int? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
        if let line {
            process.arguments = ["-l", "\(line)", url.path]
        } else {
            process.arguments = [url.path]
        }
        try? process.run()
    }
}
