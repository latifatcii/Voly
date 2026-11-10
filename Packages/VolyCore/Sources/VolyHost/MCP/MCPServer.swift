import Foundation

/// One tool an AI agent can call.
public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    /// JSON Schema of the arguments object.
    public let inputSchema: JSONValue
    /// Changes something in the running app (or relaunches it), as opposed
    /// to only reading from it.
    public let changesApp: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, changesApp: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.changesApp = changesApp
    }

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(!changesApp),
                "destructiveHint": false,
                "openWorldHint": false,
            ],
        ]
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        case image(base64: String, mimeType: String)
    }

    public var content: [Content]
    public var isError: Bool

    public init(content: [Content], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)])
    }

    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], isError: true)
    }

    /// All text parts, joined.
    public var text: String {
        content.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
    }

    public var json: JSONValue {
        let parts: [JSONValue] = content.map { part in
            switch part {
            case .text(let text):
                return ["type": "text", "text": .string(text)]
            case .image(let base64, let mimeType):
                return ["type": "image", "data": .string(base64), "mimeType": .string(mimeType)]
            }
        }
        return ["content": .array(parts), "isError": .bool(isError)]
    }

    /// Reads a result back from its wire form. Parts of a kind this server
    /// never produces are dropped.
    public init?(json: JSONValue) {
        guard let parts = json["content"]?.arrayValue else { return nil }
        content = parts.compactMap { part in
            switch part["type"]?.stringValue {
            case "text":
                return part["text"]?.stringValue.map(Content.text)
            case "image":
                guard let data = part["data"]?.stringValue else { return nil }
                return .image(base64: data, mimeType: part["mimeType"]?.stringValue ?? "image/png")
            default:
                return nil
            }
        }
        isError = json["isError"]?.boolValue ?? false
    }
}

public protocol MCPToolProviding: Sendable {
    var tools: [MCPTool] { get }
    /// Nil when there is no tool with that name.
    func call(_ name: String, arguments: JSONValue) async -> MCPToolResult?
}

/// The Model Context Protocol, server side, for a server that only offers
/// tools: JSON-RPC 2.0 messages in, JSON-RPC 2.0 messages out. Transport is
/// someone else's job — this turns one message into its reply.
///
/// It keeps no per-client state (nothing depends on `initialize` having been
/// seen), so one value can serve any number of connections.
public struct MCPServer: Sendable {
    /// Newest first. A client asking for one of these gets it; a client
    /// asking for anything else is offered the newest and decides itself.
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let title: String
    public let version: String
    public let instructions: String
    private let provider: MCPToolProviding

    public init(name: String, title: String, version: String, instructions: String, provider: MCPToolProviding) {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
        self.provider = provider
    }

    /// - Returns: the reply to send back, or nil when the message was a
    ///   notification (or a batch of them) and nothing is to be sent.
    public func handle(line: Data) async -> Data? {
        guard let message = try? JSONValue.parse(line) else {
            return Self.failure(id: .null, code: -32700, message: "Parse error").encoded()
        }
        if case .array(let batch) = message {
            guard !batch.isEmpty else {
                return Self.failure(id: .null, code: -32600, message: "Invalid Request").encoded()
            }
            var replies: [JSONValue] = []
            for entry in batch {
                if let reply = await handle(entry) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : JSONValue.array(replies).encoded()
        }
        return await handle(message)?.encoded()
    }

    private func handle(_ message: JSONValue) async -> JSONValue? {
        guard message.objectValue != nil, let method = message["method"]?.stringValue else {
            // A stray response to something we never asked: nothing to do.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.failure(id: message["id"] ?? .null, code: -32600, message: "Invalid Request")
        }
        // No id means a notification: never answered, whatever it says.
        guard let id = message["id"], !id.isNull else { return nil }
        let params = message["params"] ?? .object([:])

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let agreed = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions[0]
            return Self.success(id: id, result: [
                "protocolVersion": .string(agreed),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "title": .string(title), "version": .string(version)],
                "instructions": .string(instructions),
            ])

        case "ping":
            return Self.success(id: id, result: .object([:]))

        case "tools/list":
            return Self.success(id: id, result: ["tools": .array(provider.tools.map(\.json))])

        case "tools/call":
            guard let toolName = params["name"]?.stringValue else {
                return Self.failure(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard let result = await provider.call(toolName, arguments: arguments) else {
                return Self.failure(id: id, code: -32602, message: "Unknown tool: \(toolName)")
            }
            return Self.success(id: id, result: result.json)

        default:
            return Self.failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func success(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func failure(id: JSONValue, code: Int64, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
