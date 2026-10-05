import XCTest
import RayNeoProtocol
@testable import RayNeoCompanion

final class TeleprompterNativeTests: XCTestCase {
    func testFeatureOwnedUniformStartIntentWaitsForTransferAndIsConsumedOnce() {
        var intent = TeleprompterUniformStartIntent()
        intent.request()
        XCTAssertFalse(intent.consumeIfReady(documentReady: false, connected: true, controlIdle: true))
        XCTAssertFalse(intent.consumeIfReady(documentReady: true, connected: false, controlIdle: true))
        XCTAssertFalse(intent.consumeIfReady(documentReady: true, connected: true, controlIdle: false))
        XCTAssertTrue(intent.requested)
        XCTAssertTrue(intent.consumeIfReady(documentReady: true, connected: true, controlIdle: true))
        XCTAssertFalse(intent.consumeIfReady(documentReady: true, connected: true, controlIdle: true))
        intent.request(); intent.cancel()
        XCTAssertFalse(intent.consumeIfReady(documentReady: true, connected: true, controlIdle: true))
    }

    func testRotaryGainUsesOriginalGraphemesAcrossChineseEmojiAndCombiningLetters() throws {
        let family = "👨‍👩‍👧‍👦"
        let text = "A中" + family + "Be\u{301}文Z"
        let document = try TeleprompterNativeDocument(text: text, speed: 120, scrollMode: 3, initialOffset: 0)
        let afterA = "A".utf8.count
        let afterChinese = "A中".utf8.count
        let afterB = ("A中" + family + "B").utf8.count
        let afterAccent = ("A中" + family + "Be\u{301}").utf8.count
        XCTAssertEqual(document.rotaryTarget(previousOffset: afterA, observedOffset: afterChinese, multiplier: 3), afterB)
        XCTAssertEqual(document.rotaryTarget(previousOffset: afterAccent, observedOffset: afterB, multiplier: 3), afterChinese)
        XCTAssertEqual(document.rotaryTarget(previousOffset: afterA, observedOffset: afterChinese, multiplier: 1), afterChinese)
        XCTAssertNil(document.rotaryTarget(previousOffset: afterChinese + 1, observedOffset: afterB, multiplier: 3))
        XCTAssertNil(document.rotaryTarget(previousOffset: afterA, observedOffset: afterChinese, multiplier: .nan))
    }

    func testRotaryBurstAccumulatesLatestLogicalTargetAndClampsAtDocumentEnds() throws {
        let document = try TeleprompterNativeDocument(text: "abcdefgh", speed: 120, scrollMode: 1, initialOffset: 0)
        let first = try XCTUnwrap(document.rotaryTarget(previousOffset: 0, observedOffset: 1, multiplier: 3))
        XCTAssertEqual(first, 3)
        XCTAssertEqual(document.rotaryTarget(previousOffset: 1, observedOffset: 2, logicalOffset: first, multiplier: 3), 6)
        XCTAssertEqual(document.rotaryTarget(previousOffset: 2, observedOffset: 3, logicalOffset: 6, multiplier: 3), 8)
        XCTAssertEqual(document.rotaryTarget(previousOffset: 6, observedOffset: 5, logicalOffset: 1, multiplier: 3), 0)
    }

    func testRotaryEchoFilterIgnoresOwnInFlightAndRecentCorrectionsWithoutSuppressingNewDelta() {
        var filter = TeleprompterPositionEchoFilter()
        let position = TeleprompterNativeProgressQueue.Position(page: 12, highlight: 12)
        filter.record(position, now: 100)
        XCTAssertTrue(filter.matches(page: 12, highlight: 12, expected: nil, now: 100.1))
        XCTAssertFalse(filter.matches(page: 13, highlight: 13, expected: position, now: 100.5))
        XCTAssertFalse(filter.matches(page: 12, highlight: 15, expected: nil, now: 100.5))
        XCTAssertFalse(filter.matches(page: 12, highlight: 12, expected: nil, now: 102))
        XCTAssertTrue(filter.matches(page: 12, highlight: 12, expected: position, now: 102))
    }

    func testNormalizedProgrammaticEchoDoesNotBecomeAnotherRotaryDisplacement() {
        var filter = TeleprompterPositionEchoFilter()
        let position = TeleprompterNativeProgressQueue.Position(page: 15, highlight: 15)
        filter.record(position, now: 200)
        XCTAssertTrue(filter.matches(page: 12, highlight: 15, expected: position, now: 200.1))
        XCTAssertFalse(filter.matches(page: 12, highlight: 14, expected: position, now: 200.1))
        XCTAssertFalse(filter.matches(page: 16, highlight: 15, expected: position, now: 200.1))
        XCTAssertFalse(filter.matches(page: 12, highlight: 15, expected: position, now: 200.5))
        XCTAssertFalse(filter.matches(page: 12, highlight: 15, expected: position, now: 200.1, echoWindowSeconds: 0))
        XCTAssertTrue(filter.matches(page: 12, highlight: 15, expected: position, now: 200.5, echoWindowSeconds: 1))
    }

    func testFileTransportBasenameIsExactlyDocumentIDWithoutExtension() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TeleprompterOutboxV1")
        let did = "19beee14-4062-486b-b27b-3c48576cbfad"
        let file = try TeleprompterNativeDocument.fileURL(directory: directory, did: did)
        XCTAssertEqual(file.lastPathComponent, did)
        XCTAssertTrue(file.pathExtension.isEmpty)
        XCTAssertEqual(file.deletingLastPathComponent().path, directory.path)
        for invalid in ["", "../稿件", "id.txt", "id/name", "id\\name"] {
            XCTAssertThrowsError(try TeleprompterNativeDocument.fileURL(directory: directory, did: invalid))
        }
    }
    func testPrepareAndStartPreserveSpeechModeBytesAndInitialPosition() throws {
        let text = "第一段。\nSecond paragraph."
        let offset = "第一段。\n".utf8.count
        for mode in [1, 2, 3] {
            let document = try TeleprompterNativeDocument(text: text, speed: 180,
                                                        scrollMode: mode, initialOffset: offset)
            let prepare = try document.command(type: 2, did: "synthetic-manuscript")
            let start = try document.command(type: 3, did: "synthetic-manuscript")
            for field in ["total", "scroll", "speed", "pageOffset", "highLightOffset",
                          "countdown", "gear", "depth", "size", "width", "leading"] {
                XCTAssertEqual(DeviceBusinessWire.integer(prepare, field), DeviceBusinessWire.integer(start, field))
            }
            XCTAssertEqual(DeviceBusinessWire.integer(start, "scroll"), Int64(mode))
            XCTAssertEqual(DeviceBusinessWire.integer(start, "pageOffset"), Int64(offset))
            XCTAssertEqual(DeviceBusinessWire.integer(start, "total"), Int64(text.utf8.count))
            XCTAssertEqual(DeviceBusinessWire.integer(start, "code"), 1)
            XCTAssertEqual(start["checksum"] as? String, prepare["checksum"] as? String)
            let encoded = try DeviceBusinessWire.encode(type: 3, json: start)
            XCTAssertEqual(try DeviceBusinessWire(encoded).json["checksum"] as? String, document.checksum)
            XCTAssertEqual(document.data, Data(text.utf8))
        }
    }

    func testCompleteNativeLayoutAndSpeedAdjustmentSurviveStart() throws {
        let layout = TeleprompterNativeLayout(size: 20, width: 400, leading: 6, countdown: 0, gear: 2, depth: 3)
        let document = try TeleprompterNativeDocument(text: "中文 and English", speed: 120,
                                                     scrollMode: 2, initialOffset: 0, layout: layout)
        let start = try document.command(type: 3, did: "synthetic", speedOverride: 180)
        let settings = try document.settingsCommand(did: "synthetic", speed: 180)
        for (field, expected) in ["scroll": 2, "speed": 180, "size": 20, "width": 400,
                                  "leading": 6, "countdown": 0, "gear": 2, "depth": 3] {
            XCTAssertEqual(DeviceBusinessWire.integer(start, field), Int64(expected))
            XCTAssertEqual(DeviceBusinessWire.integer(settings, field), Int64(expected))
        }
        XCTAssertEqual(Set(settings.keys), ["action", "did", "scroll", "speed", "countdown", "gear", "depth", "size", "width", "leading"])
        XCTAssertThrowsError(try document.command(type: 3, did: "synthetic", speedOverride: 0))
    }

    func testCapturedDefaultLayoutAndGlassesStartResponseDirection() throws {
        let document = try TeleprompterNativeDocument(text: "中文稿件", speed: 120, scrollMode: 3, initialOffset: 0)
        let prepare = try document.command(type: 2, did: "synthetic")
        for (field, value) in ["size": 18, "width": 492, "leading": 4, "countdown": 3, "gear": 3, "depth": 1] {
            XCTAssertEqual(DeviceBusinessWire.integer(prepare, field), Int64(value))
        }
        let response = try document.startResponse(did: "synthetic", offset: 3, speed: 120)
        XCTAssertEqual(DeviceBusinessWire.integer(response, "action"), 2)
        XCTAssertEqual(DeviceBusinessWire.integer(response, "code"), 1)
        XCTAssertEqual(DeviceBusinessWire.integer(response, "pageOffset"), 3)
        XCTAssertEqual(DeviceBusinessWire.integer(response, "highLightOffset"), 3)
        XCTAssertNil(response["total"])
        XCTAssertNil(response["checksum"])
        XCTAssertThrowsError(try document.startResponse(did: "synthetic", offset: 1, speed: 120))
    }

    func testNativeProgressSerializesAndCoalescesTicksUntilAcknowledged() {
        var queue = TeleprompterNativeProgressQueue()
        let first = TeleprompterNativeProgressQueue.Position(page: 3, highlight: 3)
        let latest = TeleprompterNativeProgressQueue.Position(page: 12, highlight: 12)
        XCTAssertEqual(queue.enqueue(first), first)
        XCTAssertNil(queue.enqueue(.init(page: 6, highlight: 6)))
        XCTAssertNil(queue.enqueue(latest))
        XCTAssertEqual(queue.acknowledge(), latest)
        XCTAssertEqual(queue.confirmedPosition, first)
        XCTAssertTrue(queue.awaitingAcknowledgement)
        XCTAssertNil(queue.acknowledge())
        XCTAssertEqual(queue.confirmedPosition, latest)
        XCTAssertFalse(queue.awaitingAcknowledgement)
    }

    func testWheelDiscardsAutomaticQueueWithoutMisattributingLateAcknowledgement() {
        var queue = TeleprompterNativeProgressQueue()
        XCTAssertNotNil(queue.enqueue(.init(page: 3, highlight: 3)))
        XCTAssertNil(queue.enqueue(.init(page: 6, highlight: 6)))
        queue.manualAssist()
        XCTAssertTrue(queue.awaitingAcknowledgement)
        XCTAssertNil(queue.queued)
        XCTAssertNil(queue.acknowledge())
        XCTAssertNil(queue.confirmedPosition)
        XCTAssertFalse(queue.awaitingAcknowledgement)
        XCTAssertNotNil(queue.enqueue(.init(page: 30, highlight: 30)))
    }

    func testAcknowledgedOffsetIsPublishedBeforeNextQueuedPosition() {
        var queue = TeleprompterNativeProgressQueue()
        let acknowledged = TeleprompterNativeProgressQueue.Position(page: 9, highlight: 9)
        let next = TeleprompterNativeProgressQueue.Position(page: 15, highlight: 15)
        XCTAssertEqual(queue.enqueue(acknowledged), acknowledged)
        XCTAssertNil(queue.enqueue(next))
        XCTAssertEqual(queue.acknowledge(), next)
        // The pause/return anchor is the acknowledged viewport, never the
        // next queued target whose delivery is still outstanding.
        XCTAssertEqual(queue.confirmedPosition, acknowledged)
        queue.manualAssist()
        XCTAssertNil(queue.acknowledge())
        XCTAssertNil(queue.confirmedPosition)
    }

    func testUniformWheelHoldWaitsForPauseAndUsesFinalRewindDeadline() {
        var policy = TeleprompterUniformAssistPolicy()
        XCTAssertEqual(policy.rewind(now: 10, holdSeconds: 1.2, canPause: true), .pause)
        XCTAssertEqual(policy.tick(now: 12), .none)
        XCTAssertEqual(policy.rewind(now: 12, holdSeconds: 1.2, canPause: false), .none)
        XCTAssertEqual(policy.pauseAcknowledged(now: 12.1), .none)
        XCTAssertEqual(policy.tick(now: 13), .none)
        XCTAssertEqual(policy.tick(now: 13.3), .resume)
        XCTAssertEqual(policy.resumeAcknowledged(canPause: true), .none)
        XCTAssertEqual(policy.phase, .idle)
    }

    func testUniformForwardReceiptsDoNotExtendWheelHold() {
        var policy = TeleprompterUniformAssistPolicy()
        XCTAssertEqual(policy.rewind(now: 20, holdSeconds: 1.2, canPause: true), .pause)
        XCTAssertEqual(policy.pauseAcknowledged(now: 20.1), .none)
        // A forward progress receipt only updates the native offset; it does
        // not invoke rewind or establish a new hold deadline.
        XCTAssertEqual(policy.tick(now: 20.7), .none)
        XCTAssertEqual(policy.resumeAt, 21.2)
        XCTAssertEqual(policy.tick(now: 21.3), .resume)
    }

    func testUniformExpiredHoldWaitsForPendingSpeedAcknowledgement() {
        var policy = TeleprompterUniformAssistPolicy()
        XCTAssertEqual(policy.rewind(now: 24, holdSeconds: 1.2, canPause: true), .pause)
        XCTAssertEqual(policy.pauseAcknowledged(now: 24.1), .none)
        XCTAssertEqual(policy.tick(now: 25.3, readyToResume: false), .none)
        XCTAssertEqual(policy.phase, .holding)
        XCTAssertEqual(policy.resumeAt, 25.2)
        XCTAssertEqual(policy.tick(now: 26, readyToResume: true), .resume)
        XCTAssertEqual(policy.phase, .awaitingResume)
    }

    func testUniformNewRewindDuringResumeIsSerializedAfterResumeAcknowledgement() {
        var policy = TeleprompterUniformAssistPolicy()
        XCTAssertEqual(policy.rewind(now: 30, holdSeconds: 1, canPause: true), .pause)
        XCTAssertEqual(policy.pauseAcknowledged(now: 30.1), .none)
        XCTAssertEqual(policy.tick(now: 31.1), .resume)
        XCTAssertEqual(policy.rewind(now: 31.2, holdSeconds: 1.2, canPause: false), .none)
        XCTAssertEqual(policy.resumeAcknowledged(canPause: true), .pause)
        XCTAssertEqual(policy.pauseAcknowledged(now: 31.4), .none)
        XCTAssertEqual(policy.tick(now: 32.3), .none)
        XCTAssertEqual(policy.tick(now: 32.5), .resume)
    }

    func testUniformExplicitPauseCancelsPendingContinuation() {
        var policy = TeleprompterUniformAssistPolicy()
        _ = policy.rewind(now: 40, holdSeconds: 1.2, canPause: true)
        _ = policy.pauseAcknowledged(now: 40.1)
        policy.cancel()
        XCTAssertEqual(policy.tick(now: 50), .none)
        XCTAssertEqual(policy.resumeAcknowledged(canPause: true), .none)
        XCTAssertNil(policy.resumeAt)
        XCTAssertEqual(policy.rewind(now: 50, holdSeconds: 1.2, canPause: false), .none)
    }

    func testUniformNativePauseThenNearbyBackwardsReceiptIsTemporaryWheelHold() {
        var policy = TeleprompterUniformAssistPolicy()
        policy.nativePause(now: 60, wasRunning: true)
        XCTAssertEqual(policy.tick(now: 60.2), .none)
        XCTAssertEqual(policy.rewind(now: 60.3, holdSeconds: 1.2, canPause: false, pauseAssociationSeconds: 0.6), .none)
        XCTAssertTrue(policy.holding)
        XCTAssertEqual(policy.tick(now: 61.6), .resume)
    }

    func testUniformBareOrLateNativePauseDoesNotAutomaticallyResume() {
        var policy = TeleprompterUniformAssistPolicy()
        policy.nativePause(now: 70, wasRunning: true)
        XCTAssertNil(policy.resumeAt)
        XCTAssertEqual(policy.tick(now: 75), .none)
        XCTAssertEqual(policy.rewind(now: 75, holdSeconds: 1.2, canPause: false, pauseAssociationSeconds: 0.6), .none)
        XCTAssertFalse(policy.holding)
        policy.nativePause(now: 80, wasRunning: true)
        XCTAssertEqual(policy.rewind(now: 80.2, holdSeconds: 1.2, canPause: false, pauseAssociationSeconds: 0), .none)
        XCTAssertFalse(policy.holding)
    }

    func testUniformExplicitHoldClearsPauseAssociationCandidate() {
        var policy = TeleprompterUniformAssistPolicy()
        policy.nativePause(now: 90, wasRunning: true)
        policy.cancel()
        XCTAssertEqual(policy.rewind(now: 90.2, holdSeconds: 1.2, canPause: false, pauseAssociationSeconds: 0.6), .none)
        XCTAssertFalse(policy.holding)
        XCTAssertEqual(policy.tick(now: 100), .none)
    }

    func testChecksumKnownFNV1aVectorAndOriginalWhitespace() throws {
        let hello = try TeleprompterNativeDocument(text: "hello", speed: 120, scrollMode: 1, initialOffset: 0)
        XCTAssertEqual(hello.checksum, "4f9f2cab")
        let spaced = try TeleprompterNativeDocument(text: "hello\n", speed: 120, scrollMode: 1, initialOffset: 0)
        XCTAssertNotEqual(hello.checksum, spaced.checksum)
        XCTAssertEqual(spaced.data, Data("hello\n".utf8))
    }

    func testNativeOffsetsRejectMidScalarAndMidGrapheme() throws {
        let family = "👨‍👩‍👧‍👦"
        let text = family + "中文提词稿"
        XCTAssertThrowsError(try TeleprompterNativeDocument(text: text, speed: 120, scrollMode: 1, initialOffset: 1))
        XCTAssertThrowsError(try TeleprompterNativeDocument(text: text, speed: 120, scrollMode: 1, initialOffset: family.utf8.count - 1))
        let valid = try TeleprompterNativeDocument(text: text, speed: 120, scrollMode: 1, initialOffset: family.utf8.count)
        XCTAssertTrue(valid.boundaries.contains(text.utf8.count))
        XCTAssertFalse(valid.boundaries.contains(family.utf8.count + 1))
        XCTAssertThrowsError(try valid.command(type: 8, did: "synthetic"))
        XCTAssertThrowsError(try valid.command(type: 3, did: ""))
    }

    func testTypeNineAudioRequiresFieldFourAndNeverGuessesSequence() throws {
        let opus = Data([0xf8, 0xff, 0xfe])
        let packet = Data([8, 1, 16, 9, 34, 3]) + opus
        XCTAssertEqual(try BusinessEnvelopeMetadata.teleprompterAudio(packet), opus)
        XCTAssertNil(try BusinessEnvelopeMetadata.teleprompterAudio(Data([8, 1, 16, 9, 26, 3]) + opus))
    }

    @MainActor func testSimulatorCannotPrepareStartOrSeekNativeTeleprompter() {
        let store = CompanionStore()
        store.features.prepareTeleprompter("今天我们介绍产品的工作原理。", speed: 120, scrollMode: 1)
        XCTAssertNotNil(store.features.error)
        XCTAssertNil(store.features.teleprompterID)
        XCTAssertFalse(store.features.teleprompterStarted)
        XCTAssertFalse(store.features.teleprompterSeek(pageOffset: 0, highlightOffset: 0))
        store.features.teleprompterControl(3)
        XCTAssertFalse(store.features.teleprompterStarted)
    }
}
