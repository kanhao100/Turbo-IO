import XCTest
import RayNeoProtocol
@testable import RayNeoCompanion

final class TeleprompterNativeTests: XCTestCase {
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
