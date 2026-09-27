import XCTest
@testable import RayNeoProtocol

final class SubtitleDisplayTests: XCTestCase {
    private let sid = String(repeating: "a", count: 32)
    private let otherSID = String(repeating: "b", count: 32)
    private func packet(_ type: UInt8, _ body: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var data = Data([8, 1, 16, type, 26]), n = json.count
        repeat { data.append(UInt8(n & 127) | (n > 127 ? 128 : 0)); n >>= 7 } while n > 0
        data.append(json); return data
    }
    private func body(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(BusinessEnvelopeMetadata.messageJSON(data))) as? [String: Any])
    }
    private func type(_ data: Data) throws -> UInt32 { try XCTUnwrap(BusinessEnvelopeMetadata.inspect(data).messageType) }

    func testDisplayContractUsesNativeSubtitlePreviewTextAndExitOnly() throws {
        XCTAssertEqual(SubtitleDisplayWire.business, 19)
        let preview = try SubtitleDisplayWire.preview(sid: sid)
        XCTAssertEqual(try type(preview), 7)
        let p = try body(preview), config = try XCTUnwrap(p["config"] as? [String: Any])
        XCTAssertEqual(p["sid"] as? String, sid)
        XCTAssertEqual(p["scope"] as? String, "temporary"); XCTAssertEqual(p["force"] as? Bool, false)
        XCTAssertEqual(config["font_size"] as? Int, 2); XCTAssertEqual(config["content_width"] as? Int, 100)
        XCTAssertEqual(config["max_lines"] as? Int, 5); XCTAssertEqual(config["position"] as? String, "center")
        XCTAssertEqual(config["is_display"] as? Bool, true); XCTAssertEqual(config["straight_view"] as? String, "original")
        let text = try SubtitleDisplayWire.text("字幕 👓\nStreaming \"text\"", sid: sid), t = try body(text)
        XCTAssertEqual(try type(text), 5); XCTAssertEqual(t["mode"] as? Int, 3); XCTAssertEqual(t["status"] as? Int, 0)
        XCTAssertEqual((t["content"] as? [String: Any])?["source_transcript"] as? String, "字幕 👓\nStreaming \"text\"")
        let stop = try SubtitleDisplayWire.stop(sid: sid)
        XCTAssertEqual(try type(stop), 3); XCTAssertEqual(try body(stop)["reason_code"] as? Int, 10)
        for data in [preview, text, stop] {
            XCTAssertNoThrow(try SubtitleDisplayWire.validateOutbound(data))
            XCTAssertEqual(try BusinessEnvelopeMetadata.inspect(data).dataBytes ?? 0, 0)
        }
    }
    func testDisplayBoundaryRejectsRecordingForceUnknownFieldsAndOversizeText() throws {
        XCTAssertThrowsError(try SubtitleDisplayWire.validateOutbound(packet(1, ["sid": sid])))
        var preview = try body(SubtitleDisplayWire.preview(sid: sid)); preview["force"] = true
        XCTAssertThrowsError(try SubtitleDisplayWire.validateOutbound(packet(7, preview)))
        var text = try body(SubtitleDisplayWire.text("hello", sid: sid)); text["recording"] = true
        XCTAssertThrowsError(try SubtitleDisplayWire.validateOutbound(packet(5, text)))
        XCTAssertThrowsError(try SubtitleDisplayWire.validateOutbound(SubtitleDisplayWire.preview(sid: sid) + Data([34, 1, 42])))
        XCTAssertThrowsError(try SubtitleDisplayWire.text(String(repeating: "界", count: 129), sid: sid))
        XCTAssertThrowsError(try SubtitleDisplayWire.text("", sid: sid))
        XCTAssertThrowsError(try SubtitleDisplayWire.preview(sid: "old-session"))
    }
    func testNoTextBeforeMatchingACKAndDuplicateACKDoesNotRestart() throws {
        let wire = Transport(), session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
        XCTAssertFalse(session.begin(target: "glasses", confirmedIdle: false, now: 0)); XCTAssertTrue(wire.packets.isEmpty)
        XCTAssertTrue(session.begin(target: "glasses", confirmedIdle: true, now: 0))
        XCTAssertFalse(session.begin(target: "glasses", confirmedIdle: true, now: 1))
        XCTAssertFalse(session.show("too early", now: 1))
        session.receive(from: "other", packet: try packet(8, ["sid": sid, "code": 1]), now: 1)
        session.receive(from: "glasses", packet: try packet(8, ["sid": otherSID, "code": 1]), now: 1)
        XCTAssertEqual(session.phase, .opening); XCTAssertEqual(wire.packets.count, 1)
        session.receive(from: "glasses", packet: try packet(8, ["sid": sid, "code": 2]), now: 2)
        XCTAssertEqual(session.phase, .ready); XCTAssertFalse(session.wearerSawText)
        XCTAssertTrue(session.show("current frame", now: 2))
        session.receive(from: "glasses", packet: try packet(8, ["sid": sid, "code": 1]), now: 3)
        XCTAssertEqual(session.frames, 1); XCTAssertFalse(session.wearerSawText)
        session.confirmVisible(now: 3); XCTAssertTrue(session.wearerSawText)
        XCTAssertEqual(try wire.packets.map(type), [7, 5])
    }
    func testRejectedMalformedOrBooleanACKRequestsExitWithoutSendingText() throws {
        for code in [true, 0, 3, "1", 1.5] as [Any] {
            let wire = Transport(), session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
            _ = session.begin(target: "glasses", confirmedIdle: true, now: 0)
            session.receive(from: "glasses", packet: try packet(8, ["sid": sid, "code": code]), now: 1)
            XCTAssertEqual(session.phase, .stopping)
            XCTAssertEqual(try wire.packets.map(type), [7, 3])
            XCTAssertFalse(session.show("must not send", now: 2))
        }
        XCTAssertThrowsError(try SubtitleDisplayWire.reply(Data([8, 1, 16, 8, 26, 255])))
    }
    func testMissingAndLateACKTimeoutRequiresPhysicalExitConfirmation() throws {
        let wire = Transport(), session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
        _ = session.begin(target: "glasses", confirmedIdle: true, now: 0)
        session.tick(now: 10)
        session.receive(from: "glasses", packet: try packet(8, ["sid": sid, "code": 1]), now: 11)
        XCTAssertEqual(session.phase, .stopping)
        session.tick(now: 18); XCTAssertEqual(session.phase, .uncertain)
        XCTAssertTrue(session.occupied); XCTAssertEqual(try wire.packets.map(type), [7, 3])
        XCTAssertTrue(session.confirmExited(now: 19)); XCTAssertFalse(session.occupied)
        session.receive(from: "glasses", packet: try packet(8, ["sid": sid, "code": 1]), now: 20)
        XCTAssertEqual(session.phase, .idle)
    }
    func testTextRateLimitsAndOneMinuteDeadlineAreEnforced() throws {
        let wire = Transport(), session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
        _ = session.begin(target: "glasses", confirmedIdle: true, now: 0)
        session.receive(from: "glasses", packet: try packet(8, ["sid": sid, "code": 1]), now: 1)
        XCTAssertTrue(session.show("first", now: 1)); XCTAssertFalse(session.show("too fast", now: 1.1))
        for index in 1..<80 { XCTAssertTrue(session.show("frame \(index)", now: 1 + Double(index) / 2)) }
        XCTAssertFalse(session.show("over budget", now: 45)); XCTAssertEqual(session.frames, 80)
        XCTAssertFalse(session.show("past timeout", now: 60)); XCTAssertEqual(session.phase, .stopping)
        XCTAssertEqual(try type(XCTUnwrap(wire.packets.last)), 3)
    }
    func testUnexpectedAudioEndsDisplayWithoutRetainingItsContent() throws {
        let wire = Transport(), session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
        _ = session.begin(target: "glasses", confirmedIdle: true, now: 0)
        session.receive(from: "glasses", packet: Data([8, 1, 16, 4]), now: 1)
        XCTAssertEqual(session.unexpectedAudio, 1); XCTAssertEqual(session.phase, .stopping)
        XCTAssertEqual(try wire.packets.map(type), [7, 3]); XCTAssertEqual(session.frames, 0)
    }
    func testConnectionChangeNeverRedirectsCleanupAndNewSessionIgnoresOldEvents() throws {
        let wire = Transport(); var id = sid
        let session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { id })
        _ = session.begin(target: "original", confirmedIdle: true, now: 0)
        session.connectionChanged(currentDevice: "replacement", now: 1)
        XCTAssertEqual(session.phase, .uncertain); XCTAssertEqual(wire.targets, ["original"])
        XCTAssertFalse(session.begin(target: "replacement", confirmedIdle: true, now: 2))
        XCTAssertTrue(session.confirmExited(now: 2)); id = otherSID
        _ = session.begin(target: "replacement", confirmedIdle: true, now: 3)
        session.receive(from: "replacement", packet: try packet(8, ["sid": sid, "code": 1]), now: 4)
        session.transportFailed(from: "replacement", packet: try SubtitleDisplayWire.stop(sid: sid), code: 7, now: 4)
        XCTAssertEqual(session.phase, .opening)
        session.receive(from: "replacement", packet: try packet(8, ["sid": otherSID, "code": 1]), now: 4)
        XCTAssertEqual(session.phase, .ready)
    }
    func testAsyncSendFailureStopsOwnSessionAndExitFailureDoesNotLoop() throws {
        let wire = Transport(), session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
        _ = session.begin(target: "glasses", confirmedIdle: true, now: 0)
        session.transportFailed(from: "glasses", packet: try SubtitleDisplayWire.preview(sid: sid), code: 7, now: 1)
        XCTAssertEqual(try wire.packets.map(type), [7, 3])
        session.transportFailed(from: "glasses", packet: try SubtitleDisplayWire.stop(sid: sid), code: 7, now: 2)
        XCTAssertEqual(session.phase, .uncertain)
        session.tick(now: 100); XCTAssertEqual(wire.packets.count, 2)
        session.retryStop(now: 101); XCTAssertEqual(wire.packets.count, 3)
        session.tick(now: 109); XCTAssertEqual(session.phase, .uncertain)
    }
    func testFailedPreviewSubmissionCannotClaimOpenedDisplay() throws {
        let wire = Transport(); wire.succeeds = false
        let session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
        XCTAssertFalse(session.begin(target: "glasses", confirmedIdle: true, now: 0))
        XCTAssertEqual(session.phase, .uncertain); XCTAssertEqual(session.frames, 0)
        XCTAssertEqual(try wire.packets.map(type), [7, 3])
    }
    func testStopMessageAndLocalSendSuccessAreNotPhysicalExitConfirmation() throws {
        let wire = Transport(), session = SubtitleDisplaySession(send: { wire.send($0, $1) }, makeID: { self.sid })
        _ = session.begin(target: "glasses", confirmedIdle: true, now: 0)
        session.receive(from: "glasses", packet: try packet(8, ["sid": sid, "code": 1]), now: 1)
        XCTAssertFalse(session.confirmExited(now: 1))
        session.stop(now: 2)
        session.receive(from: "glasses", packet: try packet(3, ["sid": sid, "reason_code": 10]), now: 3)
        XCTAssertEqual(session.phase, .stopping); XCTAssertTrue(session.occupied)
        XCTAssertTrue(session.confirmExited(now: 3)); XCTAssertEqual(session.phase, .idle)
    }
    private final class Transport {
        var succeeds = true
        var targets: [String] = [], packets: [Data] = []
        func send(_ target: String, _ packet: Data) -> Bool { targets.append(target); packets.append(packet); return succeeds }
    }
}
