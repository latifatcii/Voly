import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

public enum Framing {
    // UIKit views can legitimately hold NaN/Infinity in Double-valued
    // properties (unlayed-out frames, infinite shadow offsets, etc). Default
    // JSONEncoder throws on those with "data couldn't be written… not in the
    // correct format", aborting the whole hierarchy response. Use matching
    // string-conversion strategies so these edge cases round-trip cleanly.
    private static let floatEncoding: JSONEncoder.NonConformingFloatEncodingStrategy =
        .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
    private static let floatDecoding: JSONDecoder.NonConformingFloatDecodingStrategy =
        .convertFromString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = floatEncoding
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = floatDecoding
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
