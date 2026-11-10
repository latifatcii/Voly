import XCTest
@testable import VolyHost

final class MCPServerTests: XCTestCase {
    private struct StubTools: MCPToolProviding {
        var tools: [MCPTool] {
            [MCPTool(name: "echo", title: "Echo", description: "Says it back.",
                     inputSchema: ["type": "object", "properties": [:]])]
        }

        func call(_ name: String, arguments: JSONValue) async -> MCPToolResult? {
            guard name == "echo" else { return nil }
            return .text("you said \(arguments["text"]?.stringValue ?? "nothing")")
        }
    }

    private let server = MCPServer(
        name: "voly", title: "Voly", version: "9.9", instructions: "Use the tools.", provider: StubTools()
    )

    private func reply(_ request: String) async throws -> JSONValue? {
        guard let data = await server.handle(line: Data(request.utf8)) else { return nil }
        XCTAssertFalse(data.contains(0x0A), "a reply must stay on one line")
        return try JSONValue.parse(data)
    }

    func test_initialize_agrees_on_a_version_the_client_asked_for() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#)
        let result = try XCTUnwrap(reply?["result"])
        XCTAssertEqual(result["protocolVersion"], "2025-03-26")
        XCTAssertEqual(result["serverInfo"]?["name"], "voly")
        XCTAssertEqual(result["serverInfo"]?["version"], "9.9")
        XCTAssertEqual(result["instructions"], "Use the tools.")
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertEqual(reply?["id"], 1)
    }

    func test_initialize_offers_its_newest_version_for_one_it_does_not_know() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(reply?["result"]?["protocolVersion"], .string(MCPServer.supportedProtocolVersions[0]))
        XCTAssertEqual(reply?["id"], "a", "string ids come back as strings")
    }

    func test_notifications_get_no_reply() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(reply)
    }

    func test_ping() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)
        XCTAssertEqual(reply?["result"], .object([:]))
    }

    func test_tools_list_carries_schema_and_hints() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tool = try XCTUnwrap(reply?["result"]?["tools"]?.arrayValue?.first)
        XCTAssertEqual(tool["name"], "echo")
        XCTAssertEqual(tool["inputSchema"]?["type"], "object")
        XCTAssertEqual(tool["annotations"]?["readOnlyHint"], true)
    }

    func test_tools_call_returns_content() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        let result = try XCTUnwrap(reply?["result"])
        XCTAssertEqual(result["isError"], false)
        XCTAssertEqual(result["content"]?.arrayValue?.first?["text"], "you said hi")
    }

    func test_an_unknown_tool_is_an_invalid_params_error() async throws {
        let reply = try await reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual(reply?["error"]?["code"], -32602)
        XCTAssertNil(reply?["result"])
    }

    func test_an_unknown_method_and_bad_json_are_reported() async throws {
        let unknown = try await reply(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)
        XCTAssertEqual(unknown?["error"]?["code"], -32601)
        let garbage = try await reply("{not json")
        XCTAssertEqual(garbage?["error"]?["code"], -32700)
        XCTAssertEqual(garbage?["id"], .null)
    }

    func test_a_batch_is_answered_as_a_batch_without_its_notifications() async throws {
        let reply = try await reply(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#)
        let replies = try XCTUnwrap(reply?.arrayValue)
        XCTAssertEqual(replies.map { $0["id"] }, [1, 2])
    }

    func test_tool_results_survive_the_wire() throws {
        let result = MCPToolResult(content: [.text("caption"), .image(base64: "QUJD", mimeType: "image/png")], isError: true)
        XCTAssertEqual(MCPToolResult(json: try JSONValue.parse(result.json.encoded())), result)
    }

    func test_json_numbers_keep_their_kind() throws {
        let value = try JSONValue.parse(Data(#"{"whole":3,"fraction":3.5,"big":12345678901,"flag":true,"none":null}"#.utf8))
        XCTAssertEqual(value["whole"], .int(3))
        XCTAssertEqual(value["fraction"], .double(3.5))
        XCTAssertEqual(value["big"]?.intValue, 12_345_678_901)
        XCTAssertEqual(value["flag"]?.boolValue, true)
        XCTAssertEqual(value["none"], .null)
        XCTAssertNil(value["fraction"]?.intValue)
        XCTAssertEqual(String(decoding: value.encoded(), as: UTF8.self),
                       #"{"big":12345678901,"flag":true,"fraction":3.5,"none":null,"whole":3}"#)
    }
}
