import XCTest
@testable import VolyHost

final class MCPSocketTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("mcp.sock").path }

    override func setUpWithError() throws {
        // Short on purpose: a socket path has to fit in sockaddr_un.
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vm-\(UInt32.random(in: 0..<999_999))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func echoListener() -> MCPSocketListener {
        MCPSocketListener(path: path) { line in
            line == Data("silent".utf8) ? nil : Data("echo:".utf8) + line
        }
    }

    func test_a_line_in_is_answered_with_a_line_out() throws {
        let listener = echoListener()
        try listener.start()
        defer { listener.stop() }
        XCTAssertTrue(MCPSocketClient.isListening(at: path))
        let reply = try MCPSocketClient.roundTrip(Data("hello".utf8), path: path, timeout: 5)
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "echo:hello")
    }

    func test_a_large_message_arrives_whole() throws {
        let listener = echoListener()
        try listener.start()
        defer { listener.stop() }
        let large = Data(repeating: UInt8(ascii: "x"), count: 3 << 20)
        let reply = try MCPSocketClient.roundTrip(large, path: path, timeout: 10)
        XCTAssertEqual(reply.count, large.count + 5)
    }

    func test_the_socket_is_private_and_removed_on_stop() throws {
        let listener = echoListener()
        try listener.start()
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        listener.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(MCPSocketClient.isListening(at: path))
    }

    func test_a_second_listener_is_refused_but_a_stale_file_is_replaced() throws {
        let first = echoListener()
        try first.start()
        XCTAssertThrowsError(try echoListener().start()) { error in
            XCTAssertEqual(error as? MCPSocketError, .inUse(path))
        }
        // The first one is untouched by the failed attempt.
        XCTAssertEqual(try MCPSocketClient.roundTrip(Data("a".utf8), path: path, timeout: 5), Data("echo:a".utf8))
        first.stop()

        FileManager.default.createFile(atPath: path, contents: Data())      // what a crash leaves behind
        let second = echoListener()
        try second.start()
        defer { second.stop() }
        XCTAssertEqual(try MCPSocketClient.roundTrip(Data("b".utf8), path: path, timeout: 5), Data("echo:b".utf8))
    }

    func test_a_path_that_cannot_be_a_socket_address_is_reported() {
        let long = directory.appendingPathComponent(String(repeating: "d", count: 120)).path
        XCTAssertThrowsError(try MCPSocketListener(path: long) { $0 }.start()) { error in
            XCTAssertEqual(error as? MCPSocketError, .pathTooLong(long))
        }
    }

    // MARK: The helper's side

    func test_without_voly_a_tool_call_says_so() async {
        let relay = RelayToolProvider(socketPath: path, launchVoly: nil)
        let result = await relay.call("list_apps", arguments: [:])
        XCTAssertEqual(result?.isError, true)
        XCTAssertTrue(result?.text.contains("Voly isn't running") ?? false)
        let unknown = await relay.call("teleport", arguments: [:])
        XCTAssertNil(unknown)
    }

    func test_the_first_call_starts_voly_and_is_answered_by_it() async throws {
        struct Tools: MCPToolProviding {
            var tools: [MCPTool] { MCPToolbox.definitions }
            func call(_ name: String, arguments: JSONValue) async -> MCPToolResult? {
                .text("\(name) from the app, root=\(arguments["root"]?.intValue ?? -1)")
            }
        }
        let app = MCPServer(name: "voly", title: "Voly", version: "t", instructions: "", provider: Tools())
        let listener = MCPSocketListener(path: path) { await app.handle(line: $0) }
        defer { listener.stop() }
        let launched = expectation(description: "Voly was started")

        var relay = RelayToolProvider(socketPath: path, launchVoly: {
            launched.fulfill()
            // A real Voly takes a moment to come up.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { try? listener.start() }
        })
        relay.launchTimeout = 10
        let result = await relay.call("get_screen", arguments: ["root": 12])
        await fulfillment(of: [launched], timeout: 1)
        XCTAssertEqual(result, .text("get_screen from the app, root=12"))
    }

    func test_the_helper_speaks_mcp_even_when_voly_is_not_there() async throws {
        let server = MCPStdioRelay.server(socketPath: path, version: "1.2", launchVoly: nil)
        let listReply = await server.handle(line: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        let listed = try JSONValue.parse(try XCTUnwrap(listReply))
        XCTAssertEqual(listed["result"]?["tools"]?.arrayValue?.count, MCPToolbox.definitions.count)
        let callReply = await server.handle(
            line: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_screen"}}"#.utf8)
        )
        let called = try JSONValue.parse(try XCTUnwrap(callReply))
        XCTAssertEqual(called["result"]?["isError"], true)
    }
}
