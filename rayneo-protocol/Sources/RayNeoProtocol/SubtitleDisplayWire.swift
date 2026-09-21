import Foundation
import CoreFoundation

/// The temporary display contract used by official-addon/SubtitleHUDCore and
/// harmony-sdk/BusinessCommands. Always requires a fresh same-session settings ACK.
/// This finite surface deliberately has no subtitle recording/start command.
public enum SubtitleDisplayWire {
    public static let business: UInt8 = 19
    public enum Failure: Error { case invalidPacket, invalidSession, invalidText }
    public struct Reply {
        public let type: UInt32
        public let sid: String?
        public let code: Int?
    }
    public static func validSession(_ sid: String) -> Bool {
        sid.utf8.count == 32 && sid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func preview(sid: String) throws -> Data {
        try encode(type: 7, sid: sid, fields: ["force": false, "scope": "temporary", "config": [
            "font_size": 2, "content_width": 100, "max_lines": 5, "position": "center",
            "is_display": true, "straight_view": "original"
        ]])
    }
    public static func text(_ text: String, sid: String) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= 384,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Failure.invalidText }
        return try encode(type: 5, sid: sid, fields: ["mode": 3, "status": 0,
            "content": ["source_transcript": text]])
    }
    public static func stop(sid: String) throws -> Data {
        try encode(type: 3, sid: sid, fields: ["reason_code": 10, "text": ""])
    }
    private static func encode(type: UInt8, sid: String, fields: [String: Any]) throws -> Data {
        guard validSession(sid) else { throw Failure.invalidSession }
        var body = fields; body["sid"] = sid
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        var packet = Data([8, 1, 16, type, 26]), count = json.count
        repeat {
            var byte = UInt8(count & 127); count >>= 7
            if count > 0 { byte |= 128 }
            packet.append(byte)
        } while count > 0
        packet.append(json); return packet
    }
    public static func reply(_ packet: Data) throws -> Reply {
        guard packet.count <= 4096 else { throw Failure.invalidPacket }
        let metadata = try BusinessEnvelopeMetadata.inspect(packet)
        guard metadata.version == 1, let type = metadata.messageType else { throw Failure.invalidPacket }
        // Audio is an unexpected event for this test. Its content is never decoded or retained.
        if type == 4 { return Reply(type: type, sid: nil, code: nil) }
        guard let data = try BusinessEnvelopeMetadata.messageJSON(packet),
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidPacket }
        let number = body["code"] as? NSNumber
        let code: Int?
        if let number, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
           abs(number.doubleValue) <= 100_000 { code = number.intValue } else { code = nil }
        return Reply(type: type, sid: body["sid"] as? String, code: code)
    }
    /// The native bridge accepts only packets produced by this display-only codec.
    public static func validateOutbound(_ packet: Data) throws {
        let reply = try reply(packet)
        guard let sid = reply.sid, validSession(sid) else { throw Failure.invalidPacket }
        let expected: Data
        switch reply.type {
        case 7: expected = try preview(sid: sid)
        case 3: expected = try stop(sid: sid)
        case 5:
            guard let data = try BusinessEnvelopeMetadata.messageJSON(packet),
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = body["content"] as? [String: Any], let value = content["source_transcript"] as? String
            else { throw Failure.invalidPacket }
            expected = try text(value, sid: sid)
        default: throw Failure.invalidPacket
        }
        guard expected == packet else { throw Failure.invalidPacket }
    }
}
