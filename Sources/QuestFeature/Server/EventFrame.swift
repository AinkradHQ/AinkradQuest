import QuestCitadelAPI
import Foundation

/// One frame of the event stream (a WebSocket text frame, or one item of an HTTP replay page), decoded on its own.
///
/// Contract rule: the server may add event types within /api/v1, and a client skips what it cannot decode. So the
/// `seq` is read first and always — the cursor moves past an unknown event — and `event` is `nil` when the
/// generated `Event` doesn't decode it.
struct EventFrame: Decodable, Sendable {
    let seq: Int64
    let event: Components.Schemas.Event?

    private enum CodingKeys: String, CodingKey { case seq }

    init(from decoder: any Decoder) throws {
        seq = try decoder.container(keyedBy: CodingKeys.self).decode(Int64.self, forKey: .seq)
        event = try? Components.Schemas.Event(from: decoder)
    }

    /// The server writes one time shape, RFC 3339 UTC with milliseconds; a whole-second time is still accepted.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not RFC 3339"))
        }
        return decoder
    }()

    static func decode(_ data: Data) throws -> EventFrame {
        try decoder.decode(EventFrame.self, from: data)
    }
}
