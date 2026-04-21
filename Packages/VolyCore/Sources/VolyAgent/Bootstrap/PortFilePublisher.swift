#if canImport(UIKit) || os(macOS)
import Foundation
import OSLog

nonisolated(unsafe) private let log = Logger(
    subsystem: "com.latifatci.VolyAgent",
    category: "PortFilePublisher"
)

/// Writes a discoverable marker file into an iOS app's sandbox `tmp` directory
/// so the macOS host process can locate the agent's WebSocket port.
///
/// File format is plain JSON so it can be eyeballed with `cat`.
public final class PortFilePublisher {
    public struct Record: Codable, Equatable {
        public let protocolVersion: Int
        public let pid: Int32
        public let port: UInt16
        public let bundleIdentifier: String
        public let processName: String
        public let issuedAt: Date
    }

    public static let fileName = "voly.port"
    public static let currentProtocolVersion = 1

    private let directory: URL
    private let clock: () -> Date

    public init(directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
                clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.clock = clock
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public func publish(port: UInt16, pid: Int32, bundleIdentifier: String, processName: String) throws {
        let record = Record(
            protocolVersion: Self.currentProtocolVersion,
            pid: pid,
            port: port,
            bundleIdentifier: bundleIdentifier,
            processName: processName,
            issuedAt: clock()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        log.notice("published port file at \(self.fileURL.path, privacy: .public)")
    }

    public func remove() {
        do {
            try FileManager.default.removeItem(at: fileURL)
            log.notice("removed port file")
        } catch CocoaError.fileNoSuchFile {
            // fine — already gone
        } catch {
            log.error("failed to remove port file: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
