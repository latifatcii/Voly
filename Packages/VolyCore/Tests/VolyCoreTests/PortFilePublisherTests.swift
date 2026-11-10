import XCTest
@testable import VolyAgent

final class PortFilePublisherTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voly-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_publish_writes_voly_port_json() throws {
        let publisher = PortFilePublisher(directory: tempDir)
        try publisher.publish(
            port: 54321,
            pid: 4242,
            bundleIdentifier: "org.test.App",
            processName: "App"
        )

        let fileURL = tempDir.appendingPathComponent("voly.port")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try decoder.decode(PortFilePublisher.Record.self, from: data)
        XCTAssertEqual(parsed.protocolVersion, 1)
        XCTAssertEqual(parsed.port, 54321)
        XCTAssertEqual(parsed.pid, 4242)
        XCTAssertEqual(parsed.bundleIdentifier, "org.test.App")
        XCTAssertEqual(parsed.processName, "App")
    }

    func test_remove_deletes_file() throws {
        let publisher = PortFilePublisher(directory: tempDir)
        try publisher.publish(port: 1, pid: 2, bundleIdentifier: "x", processName: "y")
        publisher.remove()
        let fileURL = tempDir.appendingPathComponent("voly.port")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_remove_is_idempotent() {
        let publisher = PortFilePublisher(directory: tempDir)
        publisher.remove() // no file — must not throw
    }

    func test_publish_overwrites_previous_record() throws {
        let publisher = PortFilePublisher(directory: tempDir)
        try publisher.publish(port: 1, pid: 2, bundleIdentifier: "x", processName: "y")
        try publisher.publish(port: 9, pid: 8, bundleIdentifier: "z", processName: "w")

        let data = try Data(contentsOf: tempDir.appendingPathComponent("voly.port"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try decoder.decode(PortFilePublisher.Record.self, from: data)
        XCTAssertEqual(parsed.port, 9)
        XCTAssertEqual(parsed.pid, 8)
    }

    func test_publish_uses_injected_clock_for_issuedAt() throws {
        let fixedDate = Date(timeIntervalSinceReferenceDate: 1000)
        let publisher = PortFilePublisher(directory: tempDir, clock: { fixedDate })
        try publisher.publish(port: 1, pid: 2, bundleIdentifier: "x", processName: "y")

        let data = try Data(contentsOf: tempDir.appendingPathComponent("voly.port"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try decoder.decode(PortFilePublisher.Record.self, from: data)
        XCTAssertEqual(parsed.issuedAt, fixedDate)
    }

    func test_publish_creates_intermediate_directory_if_missing() throws {
        let nested = tempDir.appendingPathComponent("does/not/exist/yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))

        let publisher = PortFilePublisher(directory: nested)
        try publisher.publish(port: 1, pid: 2, bundleIdentifier: "x", processName: "y")

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("voly.port").path))
    }

    func test_publish_writes_token_and_simulator_readable_only_by_the_owner() throws {
        let publisher = PortFilePublisher(directory: tempDir)
        try publisher.publish(
            port: 51000, pid: 77, bundleIdentifier: "com.test.App", processName: "App",
            token: "s3cret", simulatorUDID: "SIM-1"
        )
        let url = tempDir.appendingPathComponent(PortFilePublisher.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(PortFilePublisher.Record.self, from: Data(contentsOf: url))
        XCTAssertEqual(record.token, "s3cret")
        XCTAssertEqual(record.simulatorUDID, "SIM-1")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
