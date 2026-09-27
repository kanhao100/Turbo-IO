import XCTest
import RayNeoProtocol
@testable import RayNeoCompanion

final class SubtitleDisplayRuntimeTests: XCTestCase {
    @MainActor func testOpenACKStreamAndExplicitExitUseOnlyDisplayPackets() throws {
        let f = Fixture()
        f.runtime.open(confirmedIdle: false)
        XCTAssertTrue(f.packets.isEmpty); XCTAssertTrue(f.claims.isEmpty)
        f.runtime.open(confirmedIdle: true)
        XCTAssertEqual(f.runtime.phase, .opening); XCTAssertEqual(f.claims, [true])
        XCTAssertEqual(try f.types, [7]); XCTAssertEqual(f.runtime.frames, 0)
        f.runtime.play(); f.clock += 1; f.runtime.tick()
        XCTAssertEqual(f.runtime.frames, 0)
        try f.ack()
        XCTAssertEqual(f.runtime.phase, .ready); XCTAssertEqual(try f.types, [7, 5])
        XCTAssertTrue(f.runtime.expectedText.contains("字幕测试"))
        XCTAssertFalse(f.runtime.visibleConfirmed)
        f.runtime.play()
        for _ in 0..<14 { f.clock += 1; f.runtime.tick() }
        XCTAssertGreaterThan(f.runtime.frames, 10)
        XCTAssertFalse(f.runtime.playing)
        XCTAssertTrue(f.runtime.expectedText.contains("测试结束"))
        XCTAssertTrue(try f.types.allSatisfy { [7, 5].contains($0) })
        for packet in f.packets { XCTAssertNoThrow(try SubtitleDisplayWire.validateOutbound(packet)) }
        f.runtime.confirmVisible(); XCTAssertTrue(f.runtime.visibleConfirmed)
        f.runtime.stop()
        XCTAssertEqual(f.runtime.phase, .stopping); XCTAssertEqual(try f.types.last, 3)
        XCTAssertTrue(f.runtime.occupied); XCTAssertEqual(f.claims, [true])
        f.runtime.confirmExited()
        XCTAssertEqual(f.runtime.phase, .idle); XCTAssertEqual(f.claims, [true, false])
        XCTAssertFalse(f.runtime.diagnosticText.contains("private-glasses-id"))
    }
    @MainActor func testDisconnectAndUnexpectedAudioStopStreamWithoutRearming() throws {
        for audio in [true, false] {
            let f = Fixture()
            f.runtime.open(confirmedIdle: true); try f.ack(); f.runtime.play()
            if audio { f.runtime.receive(device: "private-glasses-id", packet: Data([8, 1, 16, 4])) }
            else { f.device = nil; f.runtime.connectionChanged() }
            let count = f.packets.count
            f.clock += 100; f.runtime.tick()
            XCTAssertEqual(f.runtime.phase, .uncertain); XCTAssertFalse(f.runtime.playing)
            XCTAssertEqual(f.packets.count, count)
            f.device = "private-glasses-id"; f.runtime.connectionChanged(); f.runtime.tick()
            XCTAssertEqual(f.packets.count, count)
            f.runtime.confirmExited(); XCTAssertFalse(f.runtime.occupied)
        }
    }
    @MainActor func testStopDuringOpeningIgnoresLateACKAndExplicitRetryCanTimeOut() throws {
        let f = Fixture()
        f.runtime.open(confirmedIdle: true); f.runtime.stop()
        try f.ack()
        XCTAssertEqual(f.runtime.frames, 0); XCTAssertEqual(try f.types, [7, 3])
        f.clock += 8; f.runtime.tick()
        XCTAssertTrue(f.runtime.canRetryExit)
        f.runtime.retryExit(); XCTAssertEqual(f.runtime.phase, .stopping)
        XCTAssertEqual(try f.types, [7, 3, 3])
        f.clock += 8; f.runtime.tick(); XCTAssertEqual(f.runtime.phase, .uncertain)
        f.runtime.confirmExited()
    }
    @MainActor func testBusySourceOnlyAndUnavailableDeviceNeverSend() throws {
        for condition in 0..<3 {
            let f = Fixture()
            if condition == 0 { f.available = false }
            else if condition == 1 { f.supported = false }
            else { f.device = nil }
            f.runtime.open(confirmedIdle: true)
            XCTAssertFalse(f.runtime.occupied); XCTAssertTrue(f.packets.isEmpty); XCTAssertTrue(f.claims.isEmpty)
        }
        #if !COMPANION_DEVICE
        let store = CompanionStore()
        store.subtitleDisplay.open(confirmedIdle: true)
        XCTAssertFalse(store.subtitleDisplay.occupied)
        XCTAssertFalse(store.voice.subtitleOwnsDisplay)
        XCTAssertThrowsError(try store.voice.sendSubtitle(target: "synthetic", payload: Data()))
        #endif
    }
    @MainActor func testTransportFailureLeavesVisibleDiagnosticAndRequiresExitConfirmation() throws {
        let f = Fixture()
        f.runtime.open(confirmedIdle: true)
        f.runtime.transportFailed(device: "private-glasses-id", packet: try XCTUnwrap(f.packets.first), code: 7)
        XCTAssertEqual(f.runtime.phase, .stopping); XCTAssertEqual(f.runtime.frames, 0)
        XCTAssertTrue(f.runtime.diagnosticText.contains("异步发送失败"))
        XCTAssertEqual(f.claims, [true]); f.runtime.confirmExited(); XCTAssertEqual(f.claims, [true, false])
    }
    @MainActor private final class Fixture {
        var device: String? = "private-glasses-id"
        var available = true, supported = true
        var clock: TimeInterval = 100
        var packets: [Data] = [], claims: [Bool] = []
        lazy var runtime = SubtitleDisplayRuntime(device: { [unowned self] in device },
            available: { [unowned self] in available }, supported: { [unowned self] in supported },
            claimDisplay: { [unowned self] in claims.append($0) }, send: { [unowned self] target, data in
                XCTAssertEqual(target, device); packets.append(data)
            }, uptime: { [unowned self] in clock }, scheduleTimers: false)
        var types: [UInt32] { get throws { try packets.map { try XCTUnwrap(BusinessEnvelopeMetadata.inspect($0).messageType) } } }
        func ack() throws {
            let first = try XCTUnwrap(packets.first), sid = try XCTUnwrap(SubtitleDisplayWire.reply(first).sid)
            runtime.receive(device: "private-glasses-id", packet: try DeviceBusinessWire.encode(type: 8, json: ["sid": sid, "code": 1]))
        }
    }
}
