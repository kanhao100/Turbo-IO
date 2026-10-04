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
        XCTAssertEqual(configuration.columns, 40)
        XCTAssertEqual(configuration.englishWidthPercent, 140)
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

    func testEnglishWidthPercentClampsQuantizesAndRoundTrips() throws {
        XCTAssertEqual(CaptionRollingConfiguration(englishWidthPercent: Int.min).normalized.englishWidthPercent, 100)
        XCTAssertEqual(CaptionRollingConfiguration(englishWidthPercent: Int.max).normalized.englishWidthPercent, 200)
        XCTAssertEqual(CaptionRollingConfiguration(englishWidthPercent: 134).normalized.englishWidthPercent, 130)
        XCTAssertEqual(CaptionRollingConfiguration(englishWidthPercent: 135).normalized.englishWidthPercent, 140)
        XCTAssertEqual(CaptionRollingConfiguration.allowedEnglishWidthPercents, Array(stride(from: 100, through: 200, by: 10)))
        let selected = CaptionRollingConfiguration(sourceLines: 2, columns: 32,
                                                   scrollUnit: .word, englishWidthPercent: 180)
        XCTAssertEqual(try JSONDecoder().decode(CaptionRollingConfiguration.self,
                                              from: JSONEncoder().encode(selected)), selected)
    }

    func testBuild22RollingConfigurationDecodesWithoutLosingSavedChoices() throws {
        let saved = Data(#"{"sourceLines":4,"columns":28,"scrollUnit":"word"}"#.utf8)
        let restored = try JSONDecoder().decode(CaptionRollingConfiguration.self, from: saved)
        XCTAssertEqual(restored, CaptionRollingConfiguration(sourceLines: 4, columns: 28,
                                                            scrollUnit: .word, englishWidthPercent: 140))
    }

    func testEnglishPhotoUsesTwoRowsWithRecommendedCapacityAndThreeWithOriginalCapacity() {
        let text = "secretly left the audio recorder in the office. Oh, better control. I want to see them."
        var buffer = CaptionRollingBuffer()
        buffer.updateSource(text, sentence: 1, final: true)
        let original = CaptionRollingConfiguration(columns: 40, englishWidthPercent: 100)
        XCTAssertEqual(buffer.snapshot(configuration: original).sourceLines,
                       ["secretly left the audio recorder in the",
                        "office. Oh, better control. I want to", "see them."])
        XCTAssertEqual(buffer.snapshot(configuration: configuration).sourceLines,
                       ["secretly left the audio recorder in the office. Oh,",
                        "better control. I want to see them.", " "])
        XCTAssertEqual(CaptionRollingBuffer.translationSteps(text, configuration: configuration),
                       ["secretly left the audio recorder in the office. Oh,", text])
    }

    func testEnglishCapacityDoesNotChangeChineseRows() {
        let row = "一二三四五六七八九十甲乙丙丁戊己庚辛壬癸"
        var buffer = CaptionRollingBuffer()
        buffer.updateSource(row + row + "字", sentence: 1, final: true)
        for percent in CaptionRollingConfiguration.allowedEnglishWidthPercents {
            for scrollUnit in CaptionScrollUnit.allCases {
                let selected = CaptionRollingConfiguration(columns: 40, scrollUnit: scrollUnit,
                                                           englishWidthPercent: percent)
                XCTAssertEqual(buffer.snapshot(configuration: selected).sourceLines, [row, row, "字"])
                XCTAssertEqual(CaptionRollingBuffer.translationSteps(row + row + "字", configuration: selected).last,
                               row + row + "字")
            }
        }
    }

    func testMixedScriptsKeepDigitsNarrowAndWideCharactersUnchanged() {
        let text = "0123456789 12 世界Ａ"
        var buffer = CaptionRollingBuffer()
        buffer.updateSource(text, sentence: 1, final: true)
        let original = CaptionRollingConfiguration(columns: 16, englishWidthPercent: 100)
        XCTAssertEqual(buffer.snapshot(configuration: original).sourceLines,
                       ["0123456789 12 世", "界Ａ", " "])
        let expanded = CaptionRollingConfiguration(columns: 16, englishWidthPercent: 140)
        XCTAssertEqual(buffer.snapshot(configuration: expanded).sourceLines, [text, " ", " "])
        buffer.updateSource("字", sentence: 2, final: true)
        XCTAssertEqual(buffer.snapshot(configuration: expanded).sourceLines, [text, "字", " "])
    }

    func testMaximumEnglishCapacityStillRespectsExactWireBudget() {
        let sourceRow = String(repeating: "x", count: 76)
        let translationRow = String(repeating: "y", count: 76)
        var buffer = CaptionRollingBuffer()
        buffer.updateSource(String(repeating: sourceRow, count: 3), sentence: 1, final: true)
        buffer.appendTranslation(String(repeating: translationRow, count: 2), sentence: 1)
        let expanded = CaptionRollingConfiguration(columns: 40, englishWidthPercent: 200)
        let snapshot = buffer.snapshot(configuration: expanded)
        XCTAssertEqual(snapshot.sourceLines, Array(repeating: sourceRow, count: 3))
        XCTAssertEqual(snapshot.translationLines, Array(repeating: translationRow, count: 2))
        XCTAssertEqual(snapshot.text.utf8.count, 384)
    }

    func testEnglishWrapPreservesWordsThatFitOneRow() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource("We enjoy reliable real time captions.", sentence: 1, final: true)
        let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 16, englishWidthPercent: 100))
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
        let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 16, englishWidthPercent: 100))
        XCTAssertEqual(snapshot.sourceLines, [row, row, "q"])
    }

    func testLongHistoryKeepsWrapOriginAtEveryCachedEnglishCapacity() {
        var buffer = CaptionRollingBuffer()
        buffer.updateSource(String(repeating: "x", count: 8_000), sentence: 1, final: true)
        buffer.updateSource("q", sentence: 2, final: false)
        for columns in [16, 28, 40] {
            for percent in CaptionRollingConfiguration.allowedEnglishWidthPercents {
                let selected = CaptionRollingConfiguration(columns: columns, englishWidthPercent: percent)
                let rowLength = min(76, columns * percent / 100)
                let remainder = 8_000 % rowLength
                let row = String(repeating: "x", count: rowLength)
                let tail = remainder == 0 ? "q" : String(repeating: "x", count: remainder) + " q"
                if tail.count <= rowLength {
                    XCTAssertEqual(buffer.snapshot(configuration: selected).sourceLines, [row, row, tail])
                } else {
                    XCTAssertEqual(buffer.snapshot(configuration: selected).sourceLines,
                                   [row, String(repeating: "x", count: remainder), "q"])
                }
            }
        }
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
        for percent in [100, 140, 200] {
            for scrollUnit in CaptionScrollUnit.allCases {
                let snapshot = buffer.snapshot(configuration: CaptionRollingConfiguration(columns: 40,
                    scrollUnit: scrollUnit, englishWidthPercent: percent))
                XCTAssertLessThanOrEqual(snapshot.text.utf8.count, 384)
                XCTAssertEqual(snapshot.text.components(separatedBy: "\n").count, 5)
                for row in snapshot.sourceLines + snapshot.translationLines {
                    XCTAssertLessThanOrEqual(row.utf8.count, 76)
                    XCTAssertTrue(row.allSatisfy { [Character(family), Character(accent), "字", "語", " "].contains($0) })
                }
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
        let line = CaptionRollingConfiguration(columns: 16, englishWidthPercent: 100)
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
