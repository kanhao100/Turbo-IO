import Foundation
import XCTest
@testable import RayNeoCaptions

final class SpeechScrollControllerTests: XCTestCase {
    func testObservedSentenceBecomesGradualDestinationInsteadOfJump() {
        var scroll = SpeechScrollController(text: "abcdefghijklmnopqrstuvwxyz",
            configuration: .init(maxUnitsPerSecond: 4))
        scroll.reset(toUTF8Offset: 0, now: 0)
        scroll.observe(targetUTF8Offset: 26, now: 0)
        XCTAssertEqual(scroll.displayedUTF8Offset, 0)
        var positions: [Int] = []
        for frame in 1...5 { positions.append(scroll.advance(now: Double(frame) * 0.15)) }
        XCTAssertEqual(positions, [0, 1, 1, 2, 3])
        XCTAssertLessThan(scroll.displayedUTF8Offset, 26)
    }

    func testFractionalGraphemesAccumulateWithoutRoundingSpeedUp() {
        var scroll = SpeechScrollController(text: String(repeating: "a", count: 30),
            configuration: .init(maxUnitsPerSecond: 1))
        scroll.observe(targetUTF8Offset: 30, now: 0)
        for frame in 1...6 { XCTAssertEqual(scroll.advance(now: Double(frame) * 0.15), 0) }
        XCTAssertEqual(scroll.advance(now: 1.05), 1)
        XCTAssertEqual(scroll.advance(now: 1.2), 1)
    }

    func testDuplicateObservationsCannotIncreaseRateOrExtendEvidence() {
        let configuration = SpeechScrollConfiguration(maxUnitsPerSecond: 10,
            updateIntervalSeconds: 0.1, evidenceTimeoutSeconds: 0.4)
        var plain = SpeechScrollController(text: String(repeating: "a", count: 30), configuration: configuration)
        var duplicated = plain
        plain.observe(targetUTF8Offset: 20, now: 0)
        duplicated.observe(targetUTF8Offset: 20, now: 0)
        for frame in 1...3 {
            let time = Double(frame) * 0.1
            for _ in 0..<30 { duplicated.observe(targetUTF8Offset: 20, now: time) }
            XCTAssertEqual(duplicated.advance(now: time), plain.advance(now: time))
        }
        let position = duplicated.displayedUTF8Offset
        duplicated.observe(targetUTF8Offset: 20, now: 0.39)
        XCTAssertEqual(duplicated.advance(now: 0.5), position)
        duplicated.observe(targetUTF8Offset: 20, now: 0.6)
        XCTAssertEqual(duplicated.advance(now: 0.8), position)
        duplicated.observe(targetUTF8Offset: 25, now: 0.9)
        XCTAssertGreaterThan(duplicated.advance(now: 1.1), position)
    }

    func testCorrectionCanShortenDestinationButCannotRewindOrBuyFreshTime() {
        var scroll = SpeechScrollController(text: String(repeating: "a", count: 30),
            configuration: .init(maxUnitsPerSecond: 10, updateIntervalSeconds: 0.1,
                                 evidenceTimeoutSeconds: 0.5))
        scroll.observe(targetUTF8Offset: 20, now: 0)
        XCTAssertEqual(scroll.advance(now: 0.1), 1)
        scroll.observe(targetUTF8Offset: 2, now: 0.15)
        XCTAssertEqual(scroll.advance(now: 0.3), 2)
        scroll.observe(targetUTF8Offset: 0, now: 0.35)
        XCTAssertEqual(scroll.advance(now: 0.45), 2)
        scroll.observe(targetUTF8Offset: 20, now: 0.49)
        XCTAssertEqual(scroll.advance(now: 0.7), 2)
    }

    func testUncertaintyDiscardsPendingMotionUntilNewForwardEvidence() {
        var scroll = SpeechScrollController(text: String(repeating: "a", count: 30))
        scroll.observe(targetUTF8Offset: 20, now: 0)
        let anchor = scroll.advance(now: 0.15)
        scroll.hold(now: 0.2)
        for time in [0.4, 1.0, 2.0] { XCTAssertEqual(scroll.advance(now: time), anchor) }
        scroll.observe(targetUTF8Offset: 20, now: 2.1) // Queued duplicate is not new evidence.
        XCTAssertEqual(scroll.advance(now: 2.4), anchor)
        scroll.observe(targetUTF8Offset: 25, now: 2.5)
        XCTAssertGreaterThan(scroll.advance(now: 2.7), anchor)
    }

    func testExpiredEvidenceCannotMoveOrCatchUpAfterLongStall() {
        var scroll = SpeechScrollController(text: String(repeating: "a", count: 100))
        scroll.observe(targetUTF8Offset: 60, now: 0)
        let anchor = scroll.advance(now: 0.15)
        XCTAssertEqual(scroll.advance(now: 30), anchor)
        scroll.observe(targetUTF8Offset: 60, now: 30.1)
        XCTAssertEqual(scroll.advance(now: 30.3), anchor)
        scroll.observe(targetUTF8Offset: 80, now: 30.4)
        let next = scroll.advance(now: 30.55)
        XCTAssertGreaterThan(next, anchor)
        XCTAssertLessThanOrEqual(next - anchor, 2)
    }

    func testDelayedTickIsCappedEvenWithStillRecentEvidence() {
        var scroll = SpeechScrollController(text: String(repeating: "a", count: 100))
        scroll.observe(targetUTF8Offset: 90, now: 0)
        XCTAssertEqual(scroll.advance(now: 2), 3)
        let next = scroll.advance(now: 2.15)
        XCTAssertLessThanOrEqual(next, 5)
        XCTAssertLessThan(next, 90)
    }

    func testManualAssistReanchorsThenHoldsWhileAcceptingNewSpeech() {
        var scroll = SpeechScrollController(text: String(repeating: "a", count: 30),
            configuration: .init(maxUnitsPerSecond: 10, updateIntervalSeconds: 0.1))
        scroll.observe(targetUTF8Offset: 25, now: 0)
        scroll.advance(now: 0.1)
        scroll.reset(toUTF8Offset: 10, now: 0.2, manual: true)
        XCTAssertEqual(scroll.displayedUTF8Offset, 10)
        scroll.observe(targetUTF8Offset: 20, now: 0.4)
        XCTAssertEqual(scroll.advance(now: 0.8), 10)
        XCTAssertEqual(scroll.advance(now: 1.2), 10)
        XCTAssertEqual(scroll.advance(now: 1.3), 11)
        XCTAssertEqual(scroll.advance(now: 1.4), 12)
        scroll.reset(toUTF8Offset: 0, now: 1.5, manual: true)
        XCTAssertEqual(scroll.displayedUTF8Offset, 0)
        XCTAssertEqual(scroll.advance(now: 2.7), 0) // A reset has no old queued target.
    }

    func testUnicodeEmojiCombiningMarksAndCRLFStayOnGraphemeBoundaries() {
        let parts = ["A", "👨‍👩‍👧‍👦", "e\u{301}", "\r\n", "中", "Z"]
        let text = parts.joined()
        var scroll = SpeechScrollController(text: text,
            configuration: .init(maxUnitsPerSecond: 10, updateIntervalSeconds: 0.1))
        scroll.observe(targetUTF8Offset: text.utf8.count, now: 0)
        var offset = 0
        for (index, part) in parts.enumerated() {
            offset += part.utf8.count
            XCTAssertEqual(scroll.advance(now: Double(index + 1) * 0.1), offset)
            XCTAssertNotNil(String(data: Data(text.utf8.prefix(scroll.displayedUTF8Offset)), encoding: .utf8))
        }
        scroll.reset(toUTF8Offset: 25, now: 1, manual: true)
        XCTAssertEqual(scroll.displayedUTF8Offset, 1) // Inside the family emoji.
        scroll.reset(toUTF8Offset: 28, now: 1.1)
        XCTAssertEqual(scroll.displayedUTF8Offset, 26) // Inside e + combining acute.
        scroll.reset(toUTF8Offset: 30, now: 1.2)
        XCTAssertEqual(scroll.displayedUTF8Offset, 29) // CRLF is one grapheme.
        scroll.reset(toUTF8Offset: Int.max, now: 1.3)
        XCTAssertEqual(scroll.displayedUTF8Offset, text.utf8.count)
        scroll.reset(toUTF8Offset: Int.min, now: 1.4)
        XCTAssertEqual(scroll.displayedUTF8Offset, 0)
    }

    func testBadOrRegressingClockCannotAdvanceOrInvalidateNewerState() {
        var scroll = SpeechScrollController(text: String(repeating: "a", count: 30))
        scroll.reset(toUTF8Offset: 0, now: 10)
        scroll.observe(targetUTF8Offset: 30, now: 9)
        XCTAssertEqual(scroll.advance(now: 10.15), 0)
        scroll.observe(targetUTF8Offset: 30, now: 10.2)
        let moved = scroll.advance(now: 10.5)
        XCTAssertGreaterThan(moved, 0)
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 9] {
            scroll.hold(now: invalid)
            scroll.observe(targetUTF8Offset: 0, now: invalid)
            XCTAssertEqual(scroll.advance(now: invalid), moved)
        }
        XCTAssertGreaterThan(scroll.advance(now: 10.7), moved)
    }

    func testEmptyTextAndOutOfRangeTargetsRemainBounded() {
        var empty = SpeechScrollController(text: "")
        empty.reset(toUTF8Offset: Int.max, now: 0, manual: true)
        empty.observe(targetUTF8Offset: Int.max, now: 0.5)
        XCTAssertEqual(empty.advance(now: 2), 0)
        var short = SpeechScrollController(text: "abc",
            configuration: .init(maxUnitsPerSecond: 10, updateIntervalSeconds: 0.1))
        short.observe(targetUTF8Offset: Int.max, now: 0)
        XCTAssertEqual(short.advance(now: 0.2), 2)
        XCTAssertEqual(short.advance(now: 0.3), 3)
        XCTAssertEqual(short.advance(now: 0.6), 3)
        short.observe(targetUTF8Offset: Int.min, now: 0.7)
        XCTAssertEqual(short.advance(now: 0.9), 3)
    }

    func testConfigurationNormalizationAndCodableRoundTrip() throws {
        let configuration = SpeechScrollConfiguration(maxUnitsPerSecond: .infinity,
            updateIntervalSeconds: .nan, manualAssistHoldSeconds: -5, evidenceTimeoutSeconds: 100).normalized
        XCTAssertEqual(configuration.maxUnitsPerSecond, 12)
        XCTAssertEqual(configuration.updateIntervalSeconds, 0.15)
        XCTAssertEqual(configuration.manualAssistHoldSeconds, 0)
        XCTAssertEqual(configuration.evidenceTimeoutSeconds, 10)
        XCTAssertEqual(try JSONDecoder().decode(SpeechScrollConfiguration.self,
            from: JSONEncoder().encode(configuration)), configuration)
        XCTAssertEqual(SpeechScrollConfiguration().evidenceTimeoutSeconds, 3)
    }

    func testRelaxedMatchingAcceptsMisspellingsWhileInterruptionHoldsDisplay() {
        let script = "We need to reduce costs and improve delivery efficiency. Next we discuss implementation."
        var follower = SpeechScriptFollower(text: script,
            configuration: .init(minMatchedUnits: 4, minimumSimilarity: 0.6, requiredStableUpdates: 1))
        var scroll = SpeechScrollController(text: script)
        let update = follower.recognize("we need to reduce casts and improve", final: false)
        XCTAssertTrue(update.shouldMove)
        scroll.observe(targetUTF8Offset: update.confirmedUTF8Offset, now: 0)
        XCTAssertEqual(scroll.displayedUTF8Offset, 0)
        let anchor = scroll.advance(now: 0.15)
        XCTAssertGreaterThan(anchor, 0)
        XCTAssertLessThan(anchor, update.confirmedUTF8Offset)
        let interrupted = follower.recognize("请问今天中午在哪里吃饭", final: true)
        XCTAssertEqual(interrupted.state, .uncertain)
        XCTAssertFalse(interrupted.shouldMove)
        scroll.hold(now: 0.2)
        XCTAssertEqual(scroll.advance(now: 0.6), anchor)
        XCTAssertEqual(SpeechFollowConfiguration(minimumSimilarity: 0.45).normalized.minimumSimilarity, 0.45)
        XCTAssertEqual(SpeechFollowConfiguration().minimumSimilarity, 0.8)
    }
}
