import Foundation
import VolyModels

public enum Framing {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encodeCommand(_ command: Command, id: UInt64) throws -> MessageEnvelope {
        let payload = try encoder.encode(command)
        return MessageEnvelope(id: id, kind: .command, payload: payload)
    }

    public static func encodeResponse(_ response: Response, id: UInt64) throws -> MessageEnvelope {
        let payload = try encoder.encode(response)
        return MessageEnvelope(id: id, kind: .response, payload: payload)
    }

    public static func encodeEvent(_ event: Event, id: UInt64) throws -> MessageEnvelope {
        let payload = try encoder.encode(event)
        return MessageEnvelope(id: id, kind: .event, payload: payload)
    }

    public static func encodeError(_ error: InspectorError, id: UInt64) throws -> MessageEnvelope {
        let payload = try encoder.encode(error)
        return MessageEnvelope(id: id, kind: .error, payload: payload)
    }

    public static func decodeCommand(_ envelope: MessageEnvelope) throws -> Command {
        try decoder.decode(Command.self, from: envelope.payload)
    }

    public static func decodeResponse(_ envelope: MessageEnvelope) throws -> Response {
        try decoder.decode(Response.self, from: envelope.payload)
    }

    public static func decodeEvent(_ envelope: MessageEnvelope) throws -> Event {
        try decoder.decode(Event.self, from: envelope.payload)
    }

    public static func encodeEnvelope(_ envelope: MessageEnvelope) throws -> Data {
        try encoder.encode(envelope)
    }

    public static func decodeEnvelope(_ data: Data) throws -> MessageEnvelope {
        try decoder.decode(MessageEnvelope.self, from: data)
    }
}
