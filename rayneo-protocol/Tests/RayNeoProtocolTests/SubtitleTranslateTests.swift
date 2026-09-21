import XCTest
@testable import RayNeoProtocol

final class SubtitleTranslateTests: XCTestCase {
    private let sid = "aabbcc112233"
    private func json(_ packet: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(BusinessEnvelopeMetadata.messageJSON(packet))) as? [String: Any])
    }
    func testActualNativeStartResultSettingsAndStopSchema() throws {
        let start = try SubtitleTranslateWire.start(sid: sid, language: "en-GB", saveAudio: true)
        let body = try json(start)
        XCTAssertEqual(Set(body.keys), ["sid", "trigger", "code", "settings"])
        XCTAssertEqual(body["trigger"] as? Int, 1); XCTAssertEqual(body["code"] as? Int, 0)
        XCTAssertNil(body["force"]); XCTAssertNil(body["taskId"])
        let settings = try XCTUnwrap(body["settings"] as? [String: Any])
        XCTAssertEqual(settings["mode"] as? String, "classic")
        XCTAssertEqual(settings["source_language"] as? String, "en-GB")
        XCTAssertEqual(settings["target_language"] as? String, "en-GB")
        XCTAssertEqual(settings["direction"] as? String, "around")
        XCTAssertEqual(settings["save_audio"] as? Bool, true)
        let result = try SubtitleTranslateWire.startResult(sid: sid, language: "zh-CN", saveAudio: false)
        XCTAssertNotNil(try json(result)["final_settings"])
        let stop = try SubtitleTranslateWire.stop(sid: sid)
        XCTAssertEqual(try BusinessEnvelopeMetadata.inspect(stop).messageType, 3)
        XCTAssertEqual(try json(stop)["reason_code"] as? Int, 2)
        for p in [start, result, stop, try SubtitleTranslateWire.display(sid: sid), try SubtitleTranslateWire.text("中文字幕\nLive captions", sid: sid)] {
            XCTAssertNoThrow(try SubtitleTranslateWire.validateOutbound(p))
        }
    }
    func testAudioIsTypeFourAndRequiresSessionAndStrictSequence() throws {
        func packet(_ sequence: Any, sid: String? = "aabbcc112233") throws -> Data {
            var object: [String: Any] = ["seq": sequence]
            if let sid { object["sid"] = sid }
            let body = try JSONSerialization.data(withJSONObject: object)
            return Data([8,1,16,4,26,UInt8(body.count)]) + body + Data([34,2,9,8])
        }
        let p = try packet(0), e = try SubtitleTranslateWire.event(p)
        XCTAssertEqual(e.type, 4); XCTAssertEqual(e.sequence, 0); XCTAssertEqual(e.audio, Data([9,8]))
        XCTAssertNil(try BusinessEnvelopeMetadata.assistantAudio(p))
        XCTAssertThrowsError(try SubtitleTranslateWire.event(packet(true)))
        XCTAssertThrowsError(try SubtitleTranslateWire.event(packet(-1)))
        XCTAssertThrowsError(try SubtitleTranslateWire.event(packet(1.5)))
        XCTAssertThrowsError(try SubtitleTranslateWire.event(packet(0, sid: nil)))
        XCTAssertThrowsError(try SubtitleTranslateWire.validateOutbound(p))
    }
    func testOutboundRejectsUnknownFieldsAndKeepsDisplayOnlyBoundaryClosed() throws {
        let request = try SubtitleTranslateWire.start(sid: sid, language: "zh-CN", saveAudio: false)
        XCTAssertThrowsError(try SubtitleDisplayWire.validateOutbound(request))
        XCTAssertThrowsError(try SubtitleTranslateWire.validateOutbound(request + Data([34,1,99])))
        XCTAssertThrowsError(try SubtitleTranslateWire.start(sid: "../file", language: "zh-CN", saveAudio: true))
        XCTAssertThrowsError(try SubtitleTranslateWire.start(sid: sid, language: "arbitrary", saveAudio: true))
    }
    func testShortcutPreservesEveryOtherSettingAndRequiresKnownReadback() throws {
        let original: [String: Any] = ["double": 8, "longPress": 2, "future": ["nested": true]]
        let changed = try SubtitleShortcut.replacingDouble(in: original)
        XCTAssertEqual(changed["double"] as? Int, 4); XCTAssertEqual(changed["longPress"] as? Int, 2)
        XCTAssertEqual((changed["future"] as? [String: Bool])?["nested"], true)
        XCTAssertEqual(try SubtitleShortcut.replacingDouble(in: changed, with: 8)["double"] as? Int, 8)
        XCTAssertThrowsError(try SubtitleShortcut.replacingDouble(in: ["double": 0]))
        XCTAssertThrowsError(try SubtitleShortcut.replacingDouble(in: ["double": true, "longPress": 0]))
    }
}
