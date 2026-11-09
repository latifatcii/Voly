import CryptoKit
import Foundation

/// The two simulator dylibs at stable, content-addressed paths.
public struct StagedRuntime: Equatable, Sendable {
    public let agentPath: String
    public let bridgePath: String
    public init(agentPath: String, bridgePath: String) {
        self.agentPath = agentPath
        self.bridgePath = bridgePath
    }
}

/// Copies the bundled simulator dylibs out of `Voly.app` before anything is
/// asked to load them.
///
/// Simulator processes map these files for as long as they run. Loading them
/// straight from the app bundle would mean a rebuilt or updated `Voly.app`
/// rewrites code that is mapped into running apps and into runningboardd.
/// A copy keyed by content hash never changes once written, and a new build
/// simply lands next to it.
public struct VolyRuntimeStager: Sendable {
    public enum StagingError: Error, Equatable, LocalizedError {
        case missingBundledDylib(String)
        case unusablePath(String)

        public var errorDescription: String? {
            switch self {
            case .missingBundledDylib(let path):
                return "Voly's simulator runtime is missing from the app bundle (\(path))."
            case .unusablePath(let path):
                return "Voly can't stage its simulator runtime at \(path): the path contains ':' which dyld treats as a separator."
            }
        }
    }

    public static let agentFileName = "VolyAgent.dylib"
    public static let bridgeFileName = "VolyLaunchBridge.dylib"

    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    private var runtimeRoot: URL { supportDirectory.appendingPathComponent("Runtime", isDirectory: true) }

    /// Idempotent: staging identical dylibs again returns the same paths
    /// without touching the files.
    public func stage(bundledAgent: URL, bundledBridge: URL) throws -> StagedRuntime {
        let fm = FileManager.default
        guard let agentData = try? Data(contentsOf: bundledAgent) else {
            throw StagingError.missingBundledDylib(bundledAgent.path)
        }
        guard let bridgeData = try? Data(contentsOf: bundledBridge) else {
            throw StagingError.missingBundledDylib(bundledBridge.path)
        }
        var hasher = SHA256()
        hasher.update(data: agentData)
        hasher.update(data: bridgeData)
        let digest = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()

        let directory = runtimeRoot.appendingPathComponent(digest, isDirectory: true)
        guard !directory.path.contains(":") else { throw StagingError.unusablePath(directory.path) }
        let agent = directory.appendingPathComponent(Self.agentFileName)
        let bridge = directory.appendingPathComponent(Self.bridgeFileName)

        if !fm.fileExists(atPath: agent.path) || !fm.fileExists(atPath: bridge.path) {
            // Build in a sibling directory and rename into place so a
            // half-written dylib is never visible at the final path.
            let scratch = runtimeRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            try agentData.write(to: scratch.appendingPathComponent(Self.agentFileName))
            try bridgeData.write(to: scratch.appendingPathComponent(Self.bridgeFileName))
            try? fm.removeItem(at: directory)
            try fm.moveItem(at: scratch, to: directory)
        }
        pruneStagedRuntimes(keeping: digest)
        return StagedRuntime(agentPath: agent.path, bridgePath: bridge.path)
    }

    /// Older copies are safe to unlink: processes that mapped them keep the
    /// file alive until they exit.
    private func pruneStagedRuntimes(keeping digest: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: runtimeRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != digest {
            try? fm.removeItem(at: entry)
        }
    }
}
