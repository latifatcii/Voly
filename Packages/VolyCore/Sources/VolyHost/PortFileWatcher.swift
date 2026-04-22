import Foundation
import OSLog

private let log = Logger(
    subsystem: "com.latifatci.Voly",
    category: "PortFileWatcher"
)

public final class PortFileWatcher {
    public static let defaultDevicesRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    }()

    public static let fileName = "voly.port"

    private struct Record: Decodable {
        let protocolVersion: Int
        let pid: Int32
        let port: UInt16
        let bundleIdentifier: String
        let processName: String
        let issuedAt: Date
    }

    public let devicesRoot: URL
    private let isPidAlive: (Int32) -> Bool

    public init(devicesRoot: URL = PortFileWatcher.defaultDevicesRoot,
                isPidAlive: @escaping (Int32) -> Bool = PortFileWatcher.kernelPidCheck) {
        self.devicesRoot = devicesRoot
        self.isPidAlive = isPidAlive
    }

    /// Default liveness check: `kill(pid, 0)` returns 0 if the pid exists.
    public static func kernelPidCheck(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Walks each device's Application containers and decodes any voly.port files.
    public func scan(deviceUDIDs: [String]) -> [DiscoveredAgent] {
        var results: [DiscoveredAgent] = []
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for udid in deviceUDIDs {
            let appsDir = devicesRoot
                .appendingPathComponent(udid)
                .appendingPathComponent("data/Containers/Data/Application")
            guard let children = try? fm.contentsOfDirectory(
                at: appsDir,
                includingPropertiesForKeys: nil
            ) else { continue }
            for appDir in children {
                let fileURL = appDir.appendingPathComponent("tmp/\(Self.fileName)")
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                do {
                    let rec = try decoder.decode(Record.self, from: data)
                    guard isPidAlive(rec.pid) else {
                        // Clean up the file on disk so subsequent scans don't
                        // re-log the same stale record every tick. willTerminate
                        // on the agent side doesn't fire for SIGKILL, hard stops
                        // from Xcode, or simulator shutdowns, so these linger.
                        log.info("pruning dead port file for pid \(rec.pid) (\(rec.bundleIdentifier, privacy: .public))")
                        try? fm.removeItem(at: fileURL)
                        continue
                    }
                    results.append(DiscoveredAgent(
                        deviceUDID: udid,
                        bundleIdentifier: rec.bundleIdentifier,
                        processName: rec.processName,
                        pid: rec.pid,
                        port: rec.port,
                        issuedAt: rec.issuedAt
                    ))
                } catch {
                    log.info("skipping malformed port file at \(fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return results
    }
}
