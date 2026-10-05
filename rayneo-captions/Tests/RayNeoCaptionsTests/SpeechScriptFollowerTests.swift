import Foundation
import XCTest
@testable import RayNeoCaptions

final class SpeechScriptFollowerTests: XCTestCase {
    func testGrowingPartialsConfirmContinuousChineseProgress() {
        let script = "今天我们介绍产品的工作原理。随后讨论具体应用。"
        var follower = SpeechScriptFollower(text: script)
        let first = follower.recognize("今天我们介绍", final: false)
        XCTAssertEqual(first.state, .uncertain)
        XCTAssertEqual(first.confirmedUTF8Offset, 0)
        XCTAssertEqual(first.candidateUTF8Offset, "今天我们介绍".utf8.count)
        XCTAssertFalse(first.shouldMove)

        let second = follower.recognize("今天我们介绍产品", final: false)
        XCTAssertTrue(second.shouldMove)
        XCTAssertEqual(second.confirmedUTF8Offset, "今天我们介绍产品".utf8.count)
        XCTAssertEqual(second.state, .following)
    }

    func testSamePartialCallbacksAreNotRepeatedEvidence() {
        var follower = SpeechScriptFollower(text: "今天我们介绍产品的工作原理。")
        for _ in 0..<30 {
            let result = follower.recognize("今天我们介绍", final: false)
            XCTAssertEqual(result.confirmedUTF8Offset, 0)
            XCTAssertFalse(result.shouldMove)
        }
        // A short final is a quality change, not a second independent match.
        let final = follower.recognize("今天我们介绍", final: true)
        XCTAssertEqual(final.confirmedUTF8Offset, 0)
        XCTAssertFalse(final.shouldMove)
    }

    func testStrongUniqueFinalCanFinishWithoutAnotherCallback() {
        let script = "We explain the improved battery design."
        var follower = SpeechScriptFollower(text: script)
        let result = follower.recognize("we explain the improved battery design", final: true)
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.confirmedUTF8Offset, script.utf8.count)
        XCTAssertTrue(result.shouldMove)
        XCTAssertFalse(follower.recognize("we explain the improved battery design", final: true).shouldMove)
    }

    func testFinalSegmentsAccumulateShortLocalEvidence() {
        let script = "今天我们介绍产品的工作原理。随后讨论应用。"
        var follower = SpeechScriptFollower(text: script)
        XCTAssertFalse(follower.recognize("今天我们介绍", final: true).shouldMove)
        let result = follower.recognize("产品的工作原理", final: true)
        XCTAssertTrue(result.shouldMove)
        XCTAssertEqual(result.confirmedUTF8Offset, "今天我们介绍产品的工作原理".utf8.count)
    }

    func testTinyFinalFragmentsAccumulateBeforeTheyCanMatch() {
        var follower = SpeechScriptFollower(text: "今天我们介绍产品的工作原理。随后讨论应用。")
        XCTAssertFalse(follower.recognize("今天我们", final: true).shouldMove)
        XCTAssertFalse(follower.recognize("介绍产品", final: true).shouldMove)
        let result = follower.recognize("的工作原理", final: true)
        XCTAssertTrue(result.shouldMove)
        XCTAssertEqual(result.confirmedUTF8Offset, "今天我们介绍产品的工作原理".utf8.count)
    }

    func testReturningToIdenticalSentenceAfterSwipeCanResume() {
        let first = "今天我们介绍产品的工作原理"
        var follower = SpeechScriptFollower(text: first + "。随后讨论应用。")
        XCTAssertTrue(follower.recognize(first, final: true).shouldMove)
        follower.assist(toUTF8Offset: 0)
        // Reject the queued copy once, but do not blacklist this phrase forever.
        XCTAssertFalse(follower.recognize(first, final: true).shouldMove)
        XCTAssertTrue(follower.recognize(first, final: true).shouldMove)
    }

    func testEnglishMisrecognitionAndInsertedWordPreserveManuscript() {
        let script = "We need to reduce costs and improve delivery efficiency."
        var follower = SpeechScriptFollower(text: script)
        let first = follower.recognize("We need to reduce casts", final: false)
        XCTAssertFalse(first.shouldMove)
        let result = follower.recognize("We need to reduce casts and improve", final: false)
        XCTAssertTrue(result.shouldMove)
        XCTAssertGreaterThan(result.similarity, 0.8)
        XCTAssertEqual(follower.text, script)

        var inserted = SpeechScriptFollower(text: "今天我们介绍产品的工作原理，然后讨论应用。")
        let accepted = inserted.recognize("今天我们嗯介绍产品的工作原理", final: true)
        XCTAssertTrue(accepted.shouldMove)
        XCTAssertEqual(accepted.confirmedUTF8Offset, "今天我们介绍产品的工作原理".utf8.count)
    }

    func testCorrectionWithoutNewSpeechDoesNotSupplySecondEvidence() {
        var follower = SpeechScriptFollower(text: "今天我们介绍产品的工作原理。")
        XCTAssertFalse(follower.recognize("今天我们介绍产平", final: false).shouldMove)
        XCTAssertFalse(follower.recognize("今天我们介绍产品", final: false).shouldMove)
        XCTAssertTrue(follower.recognize("今天我们介绍产品的", final: false).shouldMove)
    }

    func testInterruptionAndAdLibHoldThenNearbyScriptResumes() {
        let first = "今天我们介绍产品的工作原理"
        let second = "随后讨论具体应用以及实施方法"
        let script = first + "。" + second + "。"
        var follower = SpeechScriptFollower(text: script)
        XCTAssertTrue(follower.recognize(first, final: true).shouldMove)
        let anchor = follower.confirmedUTF8Offset
        let interruption = follower.recognize("请问这个设备多少钱", final: true)
        XCTAssertEqual(interruption.state, .uncertain)
        XCTAssertEqual(interruption.confirmedUTF8Offset, anchor)
        XCTAssertFalse(interruption.shouldMove)
        let adLib = follower.recognize("我补充一下刚才的问题", final: false)
        XCTAssertEqual(adLib.confirmedUTF8Offset, anchor)
        let resumed = follower.recognize(second, final: true)
        XCTAssertTrue(resumed.shouldMove)
        XCTAssertEqual(resumed.state, .finished)
    }

    func testOneNearbySkippedSentenceCanFollowButDistantParagraphCannot() {
        let first = "今天我们介绍产品的工作原理"
        let skip = "这句可以略过"
        let next = "随后讨论具体应用以及实施方法"
        var nearby = SpeechScriptFollower(text: first + "。" + skip + "。" + next + "。")
        XCTAssertTrue(nearby.recognize(first, final: true).shouldMove)
        XCTAssertTrue(nearby.recognize(next, final: true).shouldMove)
        XCTAssertEqual(nearby.state, .finished)

        let middle = String(repeating: "我们将展示新的设备参数与设计要求。", count: 8)
        var distant = SpeechScriptFollower(text: first + "。" + middle + next + "。")
        XCTAssertTrue(distant.recognize(first, final: true).shouldMove)
        let anchor = distant.confirmedUTF8Offset
        XCTAssertFalse(distant.recognize(next, final: true).shouldMove)
        XCTAssertEqual(distant.confirmedUTF8Offset, anchor)
        XCTAssertEqual(distant.state, .uncertain)
    }

    func testDuplicateFinalOrRereadingNearbyContentCannotAdvance() {
        let first = "今天我们介绍产品的工作原理"
        var follower = SpeechScriptFollower(text: first + "。随后讨论应用的实际效果。")
        XCTAssertTrue(follower.recognize(first, final: true).shouldMove)
        let anchor = follower.confirmedUTF8Offset
        for _ in 0..<4 {
            XCTAssertFalse(follower.recognize(first, final: true).shouldMove)
            XCTAssertEqual(follower.confirmedUTF8Offset, anchor)
        }
        XCTAssertFalse(follower.recognize("介绍产品的工作原理", final: false).shouldMove)
        XCTAssertEqual(follower.confirmedUTF8Offset, anchor)
    }

    func testRepeatedPhraseAmbiguityAndShortGenericSpeechHold() {
        var repeated = SpeechScriptFollower(text: "我们今天讨论这个产品。我们今天讨论这个产品。随后介绍原理。")
        let ambiguous = repeated.recognize("我们今天讨论这个产品", final: true)
        XCTAssertEqual(ambiguous.state, .uncertain)
        XCTAssertEqual(ambiguous.confirmedUTF8Offset, 0)
        var generic = SpeechScriptFollower(text: "So now we introduce the new battery design.")
        for text in ["so", "now", "we", "嗯", "谢谢"] {
            XCTAssertFalse(generic.recognize(text, final: true).shouldMove)
        }
        XCTAssertEqual(generic.confirmedUTF8Offset, 0)
    }

    func testManualParagraphSelectionResolvesOnlyTheSelectedRepeatedOccurrence() {
        let paragraph = "今天我们介绍产品的工作原理"
        let section = paragraph + "。\n"
        let script = section + section + section
        var follower = SpeechScriptFollower(text: script)
        XCTAssertFalse(follower.recognize(paragraph, final: true).shouldMove)
        XCTAssertEqual(follower.confirmedUTF8Offset, 0)

        let selected = section.utf8.count
        XCTAssertEqual(follower.assist(toUTF8Offset: selected).state, .waiting)
        // Ignore the identical callback that was already received before the
        // gesture, then use fresh speech to confirm the explicitly selected B.
        XCTAssertFalse(follower.recognize(paragraph, final: true).shouldMove)
        let result = follower.recognize(paragraph, final: true)
        XCTAssertTrue(result.shouldMove)
        XCTAssertEqual(result.confirmedUTF8Offset, (section + paragraph).utf8.count)
        XCTAssertLessThan(result.confirmedUTF8Offset, (section + section).utf8.count)
        XCTAssertEqual(result.state, .following)

        follower.assist(toUTF8Offset: 0)
        XCTAssertFalse(follower.recognize(paragraph, final: true).shouldMove)
        let reread = follower.recognize(paragraph, final: true)
        XCTAssertTrue(reread.shouldMove)
        XCTAssertEqual(reread.confirmedUTF8Offset, paragraph.utf8.count)
    }

    func testManualPriorAtRepeatedParagraphWorksBeforeAnyRecognition() {
        let paragraph = "今天我们介绍产品的工作原理"
        let section = paragraph + "。\n"
        var follower = SpeechScriptFollower(text: section + section + section)
        follower.assist(toUTF8Offset: section.utf8.count)
        let result = follower.recognize(paragraph, final: true)
        XCTAssertTrue(result.shouldMove)
        XCTAssertEqual(result.confirmedUTF8Offset, (section + paragraph).utf8.count)
    }

    func testManualPriorExpiresAfterTheSelectedParagraphIsConfirmed() {
        let paragraph = "今天我们介绍产品的工作原理"
        let section = paragraph + "。\n"
        var follower = SpeechScriptFollower(text: section + section + section)
        follower.assist(toUTF8Offset: section.utf8.count)
        XCTAssertTrue(follower.recognize(paragraph, final: true).shouldMove)
        let anchor = follower.confirmedUTF8Offset
        follower.recognize("观众临时问了一个新问题", final: true)
        // Speech alone cannot distinguish a repeat of B from starting C. The
        // consumed manual prior must not keep choosing occurrences forever.
        XCTAssertFalse(follower.recognize(paragraph, final: true).shouldMove)
        XCTAssertEqual(follower.confirmedUTF8Offset, anchor)
        XCTAssertEqual(follower.state, .uncertain)
    }

    func testManualPriorDoesNotAuthorizeDistantJumpOrWeakRepeatedSpeech() {
        let paragraph = "今天我们介绍产品的工作原理"
        let section = paragraph + "。\n"
        let distant = "最后总结项目成果和后续计划"
        var follower = SpeechScriptFollower(text: section + section
            + String(repeating: "我们展示新的设备参数以及设计要求。", count: 10) + distant + "。")
        follower.assist(toUTF8Offset: section.utf8.count)
        let anchor = follower.confirmedUTF8Offset
        XCTAssertFalse(follower.recognize("我们", final: true).shouldMove)
        XCTAssertFalse(follower.recognize(distant, final: true).shouldMove)
        XCTAssertEqual(follower.confirmedUTF8Offset, anchor)
    }

    func testManualSwipeAssistsWithoutEnteringPauseAndFreshSpeechContinues() {
        let first = "今天我们介绍产品的工作原理"
        let second = "随后讨论具体应用以及实施方法"
        let third = "最后总结项目成果和后续计划"
        let script = first + "。" + second + "。" + third + "。"
        var follower = SpeechScriptFollower(text: script)
        XCTAssertTrue(follower.recognize(first, final: true).shouldMove)
        let secondStart = (first + "。").utf8.count
        let assistance = follower.assist(toUTF8Offset: secondStart)
        XCTAssertEqual(assistance.state, .waiting)
        XCTAssertEqual(assistance.confirmedUTF8Offset, secondStart)
        XCTAssertFalse(follower.recognize(first, final: true).shouldMove)
        XCTAssertEqual(follower.confirmedUTF8Offset, secondStart)
        XCTAssertTrue(follower.recognize(second, final: true).shouldMove)

        let backwards = follower.assist(toUTF8Offset: 0)
        XCTAssertEqual(backwards.state, .waiting)
        XCTAssertFalse(follower.recognize(second, final: true).shouldMove)
        XCTAssertEqual(follower.confirmedUTF8Offset, 0)
        // A fresh, extended local partial can re-establish the backward anchor.
        XCTAssertFalse(follower.recognize("今天我们介绍产品", final: false).shouldMove)
        XCTAssertTrue(follower.recognize("今天我们介绍产品的工作", final: false).shouldMove)
    }

    func testManualAssistDiscardsPendingEvidence() {
        let first = "今天我们介绍产品的工作原理"
        let next = "随后讨论具体应用以及实施方法"
        var follower = SpeechScriptFollower(text: first + "。" + next + "。")
        XCTAssertFalse(follower.recognize("今天我们介绍", final: false).shouldMove)
        follower.assist(toUTF8Offset: (first + "。").utf8.count)
        XCTAssertFalse(follower.recognize("今天我们介绍", final: false).shouldMove)
        XCTAssertFalse(follower.recognize("随后讨论具体", final: false).shouldMove)
        XCTAssertTrue(follower.recognize("随后讨论具体应用", final: false).shouldMove)
    }

    func testExplicitPauseSurvivesSwipeAndResumeRequiresFreshEvidence() {
        let first = "今天我们介绍产品的工作原理"
        let next = "随后讨论具体应用以及实施方法"
        let last = "最后总结项目成果和后续计划"
        var follower = SpeechScriptFollower(text: first + "。" + next + "。" + last + "。")
        follower.pause()
        XCTAssertFalse(follower.recognize(first, final: true).shouldMove)
        XCTAssertEqual(follower.assist(toUTF8Offset: (first + "。").utf8.count).state, .paused)
        XCTAssertFalse(follower.recognize(next, final: true).shouldMove)
        XCTAssertEqual(follower.state, .paused)
        XCTAssertEqual(follower.resume().state, .waiting)
        XCTAssertFalse(follower.recognize(next, final: true).shouldMove)
        XCTAssertFalse(follower.recognize("随后讨论具体", final: false).shouldMove)
        XCTAssertTrue(follower.recognize("随后讨论具体应用", final: false).shouldMove)
    }

    func testResetRecognitionPreservesAnchorAndExplicitPause() {
        var follower = SpeechScriptFollower(text: "今天我们介绍产品的工作原理。随后讨论应用。")
        follower.recognize("今天我们介绍", final: false)
        let confirmed = follower.recognize("今天我们介绍产品", final: false)
        let reset = follower.resetRecognitionEvidence()
        XCTAssertEqual(reset.confirmedUTF8Offset, confirmed.confirmedUTF8Offset)
        XCTAssertEqual(reset.state, .waiting)
        XCTAssertFalse(follower.recognize("今天我们介绍产品", final: false).shouldMove)
        follower.pause()
        XCTAssertEqual(follower.resetRecognitionEvidence().state, .paused)
    }

    func testLiveReconfigurationPreservesPauseAndQueuedRecognitionFingerprints() {
        let first = "今天我们介绍产品的工作原理"
        let next = "随后讨论具体应用以及实施方法"
        var follower = SpeechScriptFollower(text: first + "。" + next + "。")
        follower.pause()
        XCTAssertFalse(follower.recognize(first, final: true).shouldMove)
        var configuration = follower.configuration
        configuration.minimumSimilarity = 0.6
        configuration.requiredStableUpdates = 1
        let tuned = follower.reconfigure(configuration, atUTF8Offset: 0)
        XCTAssertEqual(tuned.state, .paused)
        XCTAssertEqual(follower.configuration.minimumSimilarity, 0.6)
        follower.resume()
        XCTAssertFalse(follower.recognize(first, final: true).shouldMove)
        XCTAssertEqual(follower.confirmedUTF8Offset, 0)
        XCTAssertTrue(follower.recognize(first + "随后", final: true).shouldMove)
    }

    func testSourceUnicodeOffsetsStayOnOriginalGraphemeBoundaries() {
        let prefix = "👨‍👩‍👧‍👦 Ｃａｆé e\u{301} "
        let script = prefix + "介绍新的产品工作原理。"
        var follower = SpeechScriptFollower(text: script,
            configuration: .init(requiredStableUpdates: 1))
        let result = follower.recognize("cafe e 介绍新的产品", final: false)
        XCTAssertTrue(result.shouldMove)
        XCTAssertEqual(result.confirmedUTF8Offset, (prefix + "介绍新的产品").utf8.count)
        XCTAssertEqual(String(data: Data(script.utf8.prefix(result.confirmedUTF8Offset)), encoding: .utf8),
                       prefix + "介绍新的产品")
        let familyBytes = "👨‍👩‍👧‍👦".utf8.count
        XCTAssertEqual(follower.assist(toUTF8Offset: familyBytes - 1).confirmedUTF8Offset, 0)
        XCTAssertEqual(follower.assist(toUTF8Offset: familyBytes).confirmedUTF8Offset, familyBytes)
        XCTAssertEqual(follower.assist(toUTF8Offset: Int.max).confirmedUTF8Offset, script.utf8.count)
        XCTAssertEqual(follower.state, .finished)
        XCTAssertEqual(follower.assist(toUTF8Offset: Int.min).confirmedUTF8Offset, 0)
    }

    func testLongFinalCannotJumpBeyondMaximumForwardDistance() {
        let script = "我们介绍产品的工作原理以及实际应用。" + String(repeating: "然后展示新的实验设计以及具体结果。", count: 12)
        var follower = SpeechScriptFollower(text: script)
        let update = follower.recognize(script, final: true)
        XCTAssertFalse(update.shouldMove)
        XCTAssertEqual(update.confirmedUTF8Offset, 0)
    }

    func testEmptyOrPunctuationOnlyScriptIsFinished() {
        for script in ["", " ！？\n", "👨‍👩‍👧‍👦"] {
            var follower = SpeechScriptFollower(text: script)
            XCTAssertEqual(follower.state, .finished)
            XCTAssertEqual(follower.confirmedUTF8Offset, script.utf8.count)
            XCTAssertFalse(follower.recognize("unrelated speech", final: true).shouldMove)
        }
    }

    func testConfigurationBoundsRoundTripAndNonFiniteSimilarity() throws {
        let configuration = SpeechFollowConfiguration(maxForwardUnits: Int.max,
            lookBehindUnits: Int.min, lookAheadUnits: Int.min, minMatchedUnits: Int.max,
            minimumSimilarity: .nan, requiredStableUpdates: Int.min).normalized
        XCTAssertEqual(configuration.maxForwardUnits, 160)
        XCTAssertEqual(configuration.lookBehindUnits, 8)
        XCTAssertEqual(configuration.lookAheadUnits, 160)
        XCTAssertEqual(configuration.minMatchedUnits, 20)
        XCTAssertEqual(configuration.minimumSimilarity, 0.8)
        XCTAssertEqual(configuration.requiredStableUpdates, 1)
        XCTAssertEqual(try JSONDecoder().decode(SpeechFollowConfiguration.self,
            from: JSONEncoder().encode(configuration)), configuration)
    }
}
