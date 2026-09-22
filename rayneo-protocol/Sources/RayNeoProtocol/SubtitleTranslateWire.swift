import Foundation
import CoreFoundation

/// Native caption protocol (business 19). Audio is type 4; control/stop is type 3.
/// Pinned interoperability evidence is documented in docs/REALTIME_SUBTITLES.md.
public enum SubtitleTranslateWire {
    public static let business: UInt8 = 19
    public enum Failure: Error { case invalidPacket, invalidSession, invalidAudio, invalidMessage }
    public struct Event {
        public let type: UInt32
        public let sid: String
        public let code: Int?
        public let sequence: Int?
        public let reason: Int?
        public let end: Bool
        public let audio: Data?
    }
    public static func validSession(_ sid: String) -> Bool {
        !sid.isEmpty && sid.utf8.count <= 128 && sid.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    public static func settings(language: String, saveAudio: Bool) throws -> [String: Any] {
        guard ["zh-CN", "en-GB", "en-US"].contains(language) else { throw Failure.invalidMessage }
        return ["mode": "classic", "source_language": language, "target_language": language,
                "save_audio": saveAudio, "direction": "around"]
    }
    public static func start(sid: String, language: String, saveAudio: Bool) throws -> Data {
        // Dart's tagged 2 decodes to wire integer 1 (phone trigger). No forced takeover.
        try encode(type: 1, sid: sid, fields: ["trigger": 1, "code": 0,
            "settings": settings(language: language, saveAudio: saveAudio)])
    }
    public static func startResult(sid: String, language: String, saveAudio: Bool, code: Int = 1) throws -> Data {
        guard [1, 4, 5, 6, 7, 9, 10, 34].contains(code) else { throw Failure.invalidMessage }
        return try encode(type: 2, sid: sid, fields: ["code": code,
            "final_settings": settings(language: language, saveAudio: saveAudio)])
    }
    public static func stop(sid: String) throws -> Data {
        try encode(type: 3, sid: sid, fields: ["reason_code": 2, "text": ""])
    }
    public static func display(sid: String) throws -> Data {
        try encode(type: 7, sid: sid, fields: ["scope": "temporary", "force": false, "config": [
            "font_size": 2, "content_width": 100, "max_lines": 5, "position": "center",
            "is_display": true, "straight_view": "original"]])
    }
    public static func text(_ text: String, sid: String) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= 384, !text.utf8.contains(0) else { throw Failure.invalidMessage }
        return try encode(type: 5, sid: sid, fields: ["mode": 3, "status": 0, "content": ["source_transcript": text]])
    }
    public static func event(_ packet: Data) throws -> Event {
        guard packet.count <= 8192 else { throw Failure.invalidPacket }
        let metadata = try BusinessEnvelopeMetadata.inspect(packet)
        guard metadata.version == 1, let type = metadata.messageType, (1...11).contains(type),
              (metadata.messageBytes ?? 0) <= 4096, let json = try BusinessEnvelopeMetadata.messageJSON(packet),
              let body = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sid = body["sid"] as? String, validSession(sid) else { throw Failure.invalidPacket }
        let sequence = integer(body["seq"]), end = boolean(body["end"]) ?? false
        var audio: Data?
        if type == 4 {
            guard sequence != nil else { throw Failure.invalidAudio }
            audio = try BusinessEnvelopeMetadata.subtitleAudio(packet)
            guard audio != nil || end else { throw Failure.invalidAudio }
        }
        return Event(type: type, sid: sid, code: integer(body["code"]), sequence: sequence,
                     reason: integer(body["reason_code"]), end: end, audio: audio)
    }
    public static func validateOutbound(_ packet: Data) throws {
        let value = try event(packet)
        guard let data = try BusinessEnvelopeMetadata.messageJSON(packet),
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (try BusinessEnvelopeMetadata.inspect(packet).dataBytes ?? 0) == 0 else { throw Failure.invalidPacket }
        let expected: Data
        switch value.type {
        case 1, 2:
            let name = value.type == 1 ? "settings" : "final_settings"
            guard let fields = body[name] as? [String: Any], let language = fields["source_language"] as? String,
                  let saveAudio = boolean(fields["save_audio"]) else { throw Failure.invalidPacket }
            expected = try value.type == 1 ? start(sid: value.sid, language: language, saveAudio: saveAudio)
                : startResult(sid: value.sid, language: language, saveAudio: saveAudio, code: value.code ?? -1)
        case 3: expected = try stop(sid: value.sid)
        case 7: expected = try display(sid: value.sid)
        case 5:
            guard let content = body["content"] as? [String: Any], let text = content["source_transcript"] as? String else { throw Failure.invalidMessage }
            expected = try self.text(text, sid: value.sid)
        default: throw Failure.invalidPacket
        }
        guard packet == expected else { throw Failure.invalidPacket }
    }
    public static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded(.towardZero) == value.doubleValue,
              (0...Double(UInt32.max)).contains(value.doubleValue) else { return nil }
        return value.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func encode(type: UInt8, sid: String, fields: [String: Any]) throws -> Data {
        guard validSession(sid) else { throw Failure.invalidSession }
        var object = fields; object["sid"] = sid
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard body.count <= 4096 else { throw Failure.invalidMessage }
        var packet = Data([8, 1, 16, type, 26]), length = body.count
        repeat { var value = UInt8(length & 127); length >>= 7; if length > 0 { value |= 128 }; packet.append(value) } while length > 0
        packet.append(body); return packet
    }
}
