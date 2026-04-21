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
}
