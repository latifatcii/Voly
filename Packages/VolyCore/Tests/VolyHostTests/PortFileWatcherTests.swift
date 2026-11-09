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

    private func writePortFile(udid: String, app: String, port: Int, extra: String = "") throws {
        let tmpDir = rootDir
            .appendingPathComponent("Devices/\(udid)/data/Containers/Data/Application/\(app)/tmp")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let record = """
        {
          "protocolVersion": 1,
          "pid": 4242,
          "port": \(port),
          "bundleIdentifier": "com.test.\(app)",
          "processName": "\(app)",
          "issuedAt": "2026-04-21T14:27:03Z"\(extra)
        }
        """
        try Data(record.utf8).write(to: tmpDir.appendingPathComponent("voly.port"))
    }

    func test_scan_carries_the_agents_session_token() throws {
        try writePortFile(udid: "U", app: "WithToken", port: 5000, extra: ",\n  \"token\": \"s3cret\",\n  \"simulatorUDID\": \"U\"")
        try writePortFile(udid: "U", app: "Legacy", port: 5001)
        let watcher = PortFileWatcher(devicesRoot: rootDir.appendingPathComponent("Devices"), isPidAlive: { _ in true })
        let agents = Dictionary(uniqueKeysWithValues: watcher.scan(deviceUDIDs: ["U"]).map { ($0.processName, $0) })
        XCTAssertEqual(agents["WithToken"]?.token, "s3cret")
        // Port files from agents without auth still decode.
        XCTAssertNotNil(agents["Legacy"])
        XCTAssertNil(agents["Legacy"]?.token)
    }

    func test_scan_skips_an_agent_that_has_not_bound_a_port_yet() throws {
        try writePortFile(udid: "U", app: "NotReady", port: 0)
        let watcher = PortFileWatcher(devicesRoot: rootDir.appendingPathComponent("Devices"), isPidAlive: { _ in true })
        XCTAssertTrue(watcher.scan(deviceUDIDs: ["U"]).isEmpty)
    }
}
