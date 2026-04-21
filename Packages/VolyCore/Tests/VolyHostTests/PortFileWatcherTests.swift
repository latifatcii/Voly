import XCTest
@testable import VolyHost

final class PortFileWatcherTests: XCTestCase {
    var rootDir: URL!

    override func setUp() {
        super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voly-watcher-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootDir)
        super.tearDown()
    }

    func test_scan_finds_port_files_under_sim_container_tree() throws {
        let udid = "TEST-UDID"
        let appID = "APP-1"
        let tmpDir = rootDir
            .appendingPathComponent("Devices/\(udid)/data/Containers/Data/Application/\(appID)/tmp")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let record = """
        {
          "protocolVersion": 1,
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "port": 55555,
          "bundleIdentifier": "com.test.Fake",
          "processName": "Fake",
          "issuedAt": "2026-04-21T14:27:03Z"
        }
        """
        try record.data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("voly.port"))

        let watcher = PortFileWatcher(
            devicesRoot: rootDir.appendingPathComponent("Devices"),
            isPidAlive: { _ in true }
        )
        let agents = watcher.scan(deviceUDIDs: [udid])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].deviceUDID, udid)
        XCTAssertEqual(agents[0].bundleIdentifier, "com.test.Fake")
        XCTAssertEqual(agents[0].port, 55555)
    }

    func test_scan_drops_entries_whose_pid_is_dead() throws {
        let udid = "TEST-UDID"
        let appID = "APP-1"
        let tmpDir = rootDir
            .appendingPathComponent("Devices/\(udid)/data/Containers/Data/Application/\(appID)/tmp")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let record = """
        { "protocolVersion": 1, "pid": 424242, "port": 55555,
          "bundleIdentifier": "com.test.Dead", "processName": "Dead",
          "issuedAt": "2026-04-21T14:27:03Z" }
        """
        try record.data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("voly.port"))

        let watcher = PortFileWatcher(
            devicesRoot: rootDir.appendingPathComponent("Devices"),
            isPidAlive: { _ in false }
        )
        let agents = watcher.scan(deviceUDIDs: [udid])
        XCTAssertEqual(agents.count, 0)
    }

    func test_scan_ignores_malformed_port_files() throws {
        let udid = "TEST-UDID"
        let appID = "APP-1"
        let tmpDir = rootDir
            .appendingPathComponent("Devices/\(udid)/data/Containers/Data/Application/\(appID)/tmp")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try "not json".data(using: .utf8)!
            .write(to: tmpDir.appendingPathComponent("voly.port"))

        let watcher = PortFileWatcher(
            devicesRoot: rootDir.appendingPathComponent("Devices"),
            isPidAlive: { _ in true }
        )
        XCTAssertEqual(watcher.scan(deviceUDIDs: [udid]).count, 0)
    }
}
