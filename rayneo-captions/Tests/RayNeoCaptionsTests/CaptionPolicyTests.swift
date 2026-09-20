import XCTest
@testable import RayNeoCaptions

final class CaptionPolicyTests: XCTestCase {
    func testConservativeDefaultsAndValidatedRegion() throws {
        var options = CaptionOptions()
        XCTAssertFalse(options.recordAudio)
        XCTAssertEqual(options.idleSeconds, 900)
        XCTAssertEqual(options.maximumSeconds, 7200)
        options.region = "  EastUS\n"
        XCTAssertEqual(try options.validated().region, "eastus")
    }
    func testCannotSupplyAnArbitraryCredentialDestination() {
        for region in ["", "https://example.com", "eastus/path", "eastus.example.com", "user@host", "../", "区域"] {
            var options = CaptionOptions(); options.region = region
            XCTAssertThrowsError(try options.validated(), region)
        }
    }
    func testInvalidPolicyCannotRemoveSafetyCeiling() {
        var options = CaptionOptions(); options.region = "eastus"
        options.maximumSeconds = 0; XCTAssertThrowsError(try options.validated())
        options.maximumSeconds = 7200; options.idleSeconds = -1
        XCTAssertThrowsError(try options.validated())
        options.idleSeconds = 0; options.language = "unsupported"
        XCTAssertThrowsError(try options.validated())
    }
    func testMissingAudioIsNotSilence() {
        var options = CaptionOptions(); options.idleSeconds = 60
        let clock = CaptionClock(options: options, now: 100)
        XCTAssertEqual(clock.decision(now: 104.99), .keepListening)
        XCTAssertEqual(clock.decision(now: 105), .audioGap)
        XCTAssertEqual(clock.decision(now: 115), .stopMissingAudio)
        XCTAssertEqual(clock.decision(now: 160), .stopMissingAudio)
    }
    func testQuietAudioAndSpeechResetUseDifferentClocks() {
        var options = CaptionOptions(); options.idleSeconds = 60
        var clock = CaptionClock(options: options, now: 0)
        clock.audio(now: 59); XCTAssertEqual(clock.decision(now: 59), .keepListening)
        clock.audio(now: 60); XCTAssertEqual(clock.decision(now: 60), .stopIdle)
        clock.speech(now: 60); XCTAssertEqual(clock.decision(now: 60), .keepListening)
        clock.audio(now: 120); XCTAssertEqual(clock.decision(now: 120), .stopIdle)
    }
    func testDisabledIdleStillHasHardLimitAndMissingAudioStop() {
        var options = CaptionOptions(); options.idleSeconds = 0
        var clock = CaptionClock(options: options, now: 0)
        for second in 1..<7200 {
            clock.audio(now: Double(second))
            XCTAssertEqual(clock.decision(now: Double(second)), .keepListening)
        }
        clock.audio(now: 7200); XCTAssertEqual(clock.decision(now: 7200), .stopLimit)
        XCTAssertEqual(clock.decision(now: 9000), .stopLimit)
    }
    func testOldTimestampsDoNotRewindTimers() {
        var clock = CaptionClock(options: CaptionOptions(), now: 100)
        clock.audio(now: 99); clock.speech(now: 98)
        XCTAssertEqual(clock.lastAudio, 100); XCTAssertEqual(clock.lastSpeech, 100)
    }
    func testVADRejectsOneClickAndNeedsSustainedFrames() {
        var activity = CaptionVoiceActivity()
        XCTAssertFalse(activity.accept(true))
        for _ in 0..<20 { XCTAssertFalse(activity.accept(false)) }
        for _ in 0..<11 { XCTAssertFalse(activity.accept(true)) }
        XCTAssertTrue(activity.accept(true))
        XCTAssertFalse(activity.accept(false))
    }
    func testCloudRetryBudgetIsBoundedUntilUsefulRecognition() {
        var budget = CaptionRetryBudget()
        XCTAssertEqual(budget.nextDelay(), 1)
        XCTAssertEqual(budget.nextDelay(), 2)
        XCTAssertEqual(budget.nextDelay(), 4)
        XCTAssertNil(budget.nextDelay()); XCTAssertNil(budget.nextDelay())
        budget.recognized(); XCTAssertEqual(budget.nextDelay(), 1)
    }
    func testLensWindowKeepsNewestWholeGraphemes() {
        let cluster = "👨‍👩‍👧‍👦e\u{301}字幕"
        let full = String(repeating: cluster, count: 200)
        let result = CaptionText.lensWindow(full)
        XCTAssertLessThanOrEqual(result.utf8.count, 480)
        XCTAssertTrue(full.hasSuffix(result)); XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(CaptionText.lensWindow("早安", maximumBytes: 3), "安")
        XCTAssertEqual(CaptionText.lensWindow("👨‍👩‍👧‍👦", maximumBytes: 1), "")
        XCTAssertEqual(CaptionText.lensWindow("abc", maximumBytes: 0), "")
    }
}
