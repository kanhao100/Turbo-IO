import XCTest
@testable import RayNeoCaptions

final class CaptionRollingBufferTests: XCTestCase {
    private let configuration = CaptionRollingConfiguration()

    func testContinuousSpeechDoesNotHideThePreviousTranslation() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("第一段已经说完。", sentence: 1, final: true)
        buffer.updateSource("第二段还在继续", sentence: 2, final: false)
        buffer.appendTranslation("The first part is done.", sentence: 1)

        let first = buffer.snapshot(configuration: configuration)
        XCTAssertEqual(first.sourceText.replacingOccurrences(of: "\n", with: ""), "第一段已经说完。第二段还在继续")
        XCTAssertEqual(first.translationText, "The first part is done.")

        buffer.updateSource("第二段还在继续说话。", sentence: 2, final: false)
        let next = buffer.snapshot(configuration: configuration)
        XCTAssertTrue(next.sourceText.replacingOccurrences(of: "\n", with: "").contains("第二段还在继续说话。"))
        XCTAssertEqual(next.translationLines, first.translationLines)
    }

    func testRevisedDraftReplacesThePreviousDraftAndFinalCommitsOnlyOnce() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("We need", sentence: 1, final: true)
        buffer.updateSource("the blue bus", sentence: 2, final: false)
        buffer.updateSource("the green bus", sentence: 2, final: false)
        XCTAssertEqual(buffer.snapshot(configuration: configuration).sourceText, "We need the green bus")
        buffer.updateSource("the green bus", sentence: 2, final: true)
        buffer.updateSource("the green bus", sentence: 2, final: true)
        buffer.updateSource("a stale revision", sentence: 2, final: false)
        buffer.updateSource("obsolete", sentence: 1, final: true)
        XCTAssertEqual(buffer.snapshot(configuration: configuration).sourceText, "We need the green bus")
    }

    func testSourceAndTranslationSequenceNumbersAdvanceIndependently() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("当前原文", sentence: 20, final: false)
        buffer.appendTranslation("Previous speech", sentence: 3)
        buffer.updateTranslation("Next translated draft", sentence: 4, final: false)
        buffer.appendTranslation("Late obsolete result", sentence: 2)
        buffer.updateSource("迟到的原文", sentence: 19, final: true)
        let snapshot = buffer.snapshot(configuration: configuration)
        XCTAssertEqual(snapshot.sourceText, "当前原文")
        XCTAssertTrue(snapshot.translationText.replacingOccurrences(of: "\n", with: " ")
            .contains("Next translated draft"))
        XCTAssertFalse(snapshot.translationText.contains("Late obsolete"))
    }

    func testTranslationDraftRevealDoesNotAppendRepeatedPrefixes() {
        var buffer = CaptionRollingBuffer()
        buffer.appendTranslation("Earlier.", sentence: 1)
        buffer.updateTranslation("A newly", sentence: 2, final: false)
        buffer.updateTranslation("A newly translated sentence.", sentence: 2, final: false)
        buffer.appendTranslation("A newly translated sentence.", sentence: 2)
        let once = buffer.snapshot(configuration: configuration)
        buffer.appendTranslation("A newly translated sentence.", sentence: 2)
        buffer.updateTranslation("Revoked old wording", sentence: 2, final: false)
        XCTAssertEqual(buffer.snapshot(configuration: configuration), once)
        XCTAssertEqual(once.translationText.components(separatedBy: "A newly").count, 2)
    }

    func testEveryVisibilityModeReservesExactlyFivePhysicalRows() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("原文", sentence: 1, final: true)
        buffer.appendTranslation("Translation", sentence: 1)
        let bilingual = buffer.snapshot(configuration: configuration)
        XCTAssertEqual(bilingual.sourceLines, ["原文", " ", " "])
        XCTAssertEqual(bilingual.translationLines, ["Translation", " "])
        for sourceVisible in [false, true] {
            for translationVisible in [false, true] {
                let snapshot = buffer.snapshot(configuration: configuration,
                                               sourceVisible: sourceVisible,
                                               translationVisible: translationVisible)
                XCTAssertEqual(snapshot.text.components(separatedBy: "\n").count, 5)
                XCTAssertFalse(snapshot.text.components(separatedBy: "\n").contains(""))
                XCTAssertLessThanOrEqual(snapshot.text.utf8.count, 384)
                if sourceVisible && !translationVisible { XCTAssertEqual(snapshot.sourceLines.count, 5) }
                if translationVisible && !sourceVisible { XCTAssertEqual(snapshot.translationLines.count, 5) }
            }
        }
        XCTAssertEqual(buffer.snapshot(configuration: configuration, sourceVisible: false,
                                       translationVisible: false).text, " \n \n \n \n ")
    }

    func testConfigurationClampsAndRoundTrips() throws {
        let low = CaptionRollingConfiguration(sourceLines: -1, columns: 2)
        XCTAssertEqual(low.normalized.sourceLines, 1)
        XCTAssertEqual(low.normalized.columns, 16)
        XCTAssertEqual(low.translationLines, 4)
        let high = CaptionRollingConfiguration(sourceLines: 20, columns: 200, scrollUnit: .word)
        XCTAssertEqual(high.normalized, CaptionRollingConfiguration(sourceLines: 4, columns: 40, scrollUnit: .word))
        XCTAssertEqual(high.translationLines, 1)
        XCTAssertEqual(try JSONDecoder().decode(CaptionRollingConfiguration.self,
                                              from: JSONEncoder().encode(high)), high)
    }

    func testEnglishWrapPreservesWordsThatFitOneRow() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("We enjoy reliable real time captions.", sentence: 1, final: true)
        let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 16))
        XCTAssertEqual(snapshot.sourceLines, ["We enjoy", "reliable real", "time captions."])
    }

    func testLineScrollEvictsWholeRowsAndWordScrollReanchorsAtWords() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("一二三四五六七八九十甲乙丙丁戊己", sentence: 1, final: true)
        let line = CaptionRollingConfiguration(sourceLines: 2, columns: 16)
        let before = buffer.snapshot(configuration: line)
        buffer.updateSource("庚", sentence: 2, final: false)
        let after = buffer.snapshot(configuration: line)
        XCTAssertEqual(before.sourceLines, ["一二三四五六七八", "九十甲乙丙丁戊己"])
        XCTAssertEqual(after.sourceLines, [before.sourceLines[1], "庚"])

        var word = line
        word.scrollUnit = .word
        XCTAssertEqual(buffer.snapshot(configuration: word).sourceLines,
                       ["二三四五六七八九", "十甲乙丙丁戊己庚"])
    }

    func testLongHistoryKeepsTheLineOriginAfterMemoryCompaction() {
        var buffer = CaptionRollingBuffer()
        let row = "abcdefghijklmnop"
        buffer.updateSource(String(repeating: row, count: 500), sentence: 1, final: true)
        buffer.updateSource("q", sentence: 2, final: false)
        let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 16))
        XCTAssertEqual(snapshot.sourceLines, [row, row, "q"])
    }

    func testOversizedEnglishWordRemainsVisibleInExperimentalWordMode() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource(String(repeating: "identifier", count: 100), sentence: 1, final: true)
        let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 16, scrollUnit: .word))
        XCTAssertFalse(snapshot.sourceText.isEmpty)
        XCTAssertEqual(snapshot.sourceLines.count, 3)
        XCTAssertLessThanOrEqual(snapshot.text.utf8.count, 384)
    }

    func testUnicodeGraphemesRemainWholeAndRespectTheWireBudget() {
        let family = "👨‍👩‍👧‍👦"
        let accent = "e\u{301}"
        var buffer = CaptionRollingBuffer()
        buffer.updateSource(String(repeating: family + accent + "字", count: 100), sentence: 1, final: true)
        buffer.appendTranslation(String(repeating: family + accent + "語", count: 100), sentence: 1)
        for scrollUnit in CaptionScrollUnit.allCases {
            let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 40, scrollUnit: scrollUnit))
            XCTAssertLessThanOrEqual(snapshot.text.utf8.count, 384)
            XCTAssertEqual(snapshot.text.components(separatedBy: "\n").count, 5)
            for row in snapshot.sourceLines + snapshot.translationLines {
                XCTAssertLessThanOrEqual(row.utf8.count, 76)
                XCTAssertTrue(row.allSatisfy { [Character(family), Character(accent), "字", "語", " "].contains($0) })
            }
        }
    }

    func testOversizedSingleGraphemeIsElidedWithoutBreakingIt() {
        var buffer = CaptionRollingBuffer()
        let oversized = "e" + String(repeating: "\u{301}", count: 100)
        buffer.updateSource(oversized + "安全", sentence: 1, final: true)
        let snapshot = buffer.snapshot(configuration: configuration)
        XCTAssertEqual(snapshot.sourceText, "…安全")
        XCTAssertLessThanOrEqual(snapshot.text.utf8.count, 384)
    }

    func testInputNewlinesAndControlCharactersCannotChangeTheFiveRowLayout() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("  First\n\nsecond\tthird\u{0}\r\nfourth  ", sentence: 1, final: true)
        let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 40))
        XCTAssertEqual(snapshot.sourceText, "First second third fourth")
        XCTAssertEqual(snapshot.text.components(separatedBy: "\n").count, 5)
    }

    func testLongTranslationExposesEachLineBeforeTheTailWindowAdvances() {
        let text = "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥"
        let configuration = CaptionRollingConfiguration(sourceLines: 3, columns: 16)
        let steps = CaptionRollingBuffer.translationSteps(text, configuration: configuration)
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.first, "一二三四五六七八")
        XCTAssertEqual(steps.last, text)

        var buffer = CaptionRollingBuffer()
        var revealed = Set<Character>()
        for (index, step) in steps.enumerated() {
            buffer.updateTranslation(step, sentence: 1, final: index == steps.count - 1)
            let snapshot = buffer.snapshot(configuration: configuration)
            revealed.formUnion(snapshot.translationText.filter { !$0.isWhitespace })
        }
        XCTAssertEqual(revealed, Set(text))
    }

    func testTranslationStepsUseTheSameWordWrappingAndUnicodeBudget() {
        let line = CaptionRollingConfiguration(columns: 16)
        XCTAssertEqual(CaptionRollingBuffer.translationSteps("We enjoy reliable real time captions.", configuration: line),
                       ["We enjoy", "We enjoy reliable real", "We enjoy reliable real time captions."])
        var word = line
        word.scrollUnit = .word
        XCTAssertEqual(CaptionRollingBuffer.translationSteps("Hello 世界", configuration: word),
                       ["Hello", "Hello 世", "Hello 世界"])
        let family = "👨‍👩‍👧‍👦"
        let steps = CaptionRollingBuffer.translationSteps(String(repeating: family, count: 7),
                                                         configuration: CaptionRollingConfiguration(columns: 40))
        XCTAssertEqual(steps.map(\.count), [3, 6, 7])
        XCTAssertTrue(CaptionRollingBuffer.translationSteps(" \n\t ", configuration: line).isEmpty)
    }

    func testResetClearsBothChannelsAndSequenceNumbers() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("Old source", sentence: 50, final: true)
        buffer.appendTranslation("Old translation", sentence: 50)
        buffer.reset()
        buffer.updateSource("New source", sentence: 1, final: true)
        buffer.appendTranslation("New translation", sentence: 1)
        let snapshot = buffer.snapshot(configuration: configuration)
        XCTAssertEqual(snapshot.sourceText, "New source")
        XCTAssertEqual(snapshot.translationText, "New translation")
    }
}
