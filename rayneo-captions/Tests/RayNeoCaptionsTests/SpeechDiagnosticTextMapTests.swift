import XCTest
@testable import RayNeoCaptions

final class SpeechDiagnosticTextMapTests: XCTestCase {
    func testMatchedEndpointSkipsFinalPunctuationAndUsesOriginalGraphemes() throws {
        let text = "👨‍👩‍👧‍👦 Ｃａｆé e\u{301} 介绍原理。\n"
        let map = SpeechDiagnosticTextMap(text: text)
        let position = try XCTUnwrap(map.matchedPosition(endingAtUTF8Offset: text.utf8.count))
        XCTAssertEqual(position.character, "理")
        XCTAssertEqual(position.word, "理")
        XCTAssertEqual(position.characterIndex, text.count - 3)
        XCTAssertEqual(position.utf8Range, (text.utf8.count - 7)..<(text.utf8.count - 4))
        XCTAssertEqual(position.wordRangeUTF8, position.utf8Range)
        XCTAssertEqual(position.highlight, "理")
        XCTAssertEqual(position.after, "。\n")
        XCTAssertEqual(position.before + position.highlight + position.after, text)
    }

    func testLatinWordAndDisplayCursorUseSeparateOriginalRanges() throws {
        let text = "Hello don't stop. 继续。"
        let map = SpeechDiagnosticTextMap(text: text)
        let matched = try XCTUnwrap(map.matchedPosition(endingAtUTF8Offset: "Hello don't".utf8.count))
        XCTAssertEqual(matched.character, "t")
        XCTAssertEqual(matched.characterIndex, 10)
        XCTAssertEqual(matched.word, "don't")
        XCTAssertEqual(matched.utf8Range, 10..<11)
        XCTAssertEqual(matched.wordRangeUTF8, 6..<11)
        let shown = try XCTUnwrap(map.displayedPosition(atUTF8Offset: 5))
        XCTAssertEqual(shown.character, "d")
        XCTAssertEqual(shown.characterIndex, 6)
        XCTAssertEqual(shown.wordRangeUTF8, 6..<11)
    }

    func testInteriorBytesCannotSplitEmojiOrCombiningAccent() throws {
        let family = "👨‍👩‍👧‍👦", accent = "e\u{301}"
        let text = family + accent + "！"
        let map = SpeechDiagnosticTextMap(text: text)
        for offset in 0..<family.utf8.count {
            let shown = try XCTUnwrap(map.displayedPosition(atUTF8Offset: offset))
            XCTAssertEqual(shown.characterIndex, 0)
            XCTAssertEqual(shown.character, family)
            XCTAssertEqual(shown.utf8Range, 0..<family.utf8.count)
            XCTAssertNil(map.matchedPosition(endingAtUTF8Offset: offset))
        }
        let accentEnd = family.utf8.count + accent.utf8.count
        let shown = try XCTUnwrap(map.displayedPosition(atUTF8Offset: accentEnd - 1))
        XCTAssertEqual(shown.character, accent)
        XCTAssertEqual(shown.utf8Range, family.utf8.count..<accentEnd)
        XCTAssertNil(map.matchedPosition(endingAtUTF8Offset: accentEnd - 1))
        XCTAssertEqual(map.matchedPosition(endingAtUTF8Offset: accentEnd)?.character, accent)
        XCTAssertEqual(map.matchedPosition(endingAtUTF8Offset: Int.max)?.character, accent)
        XCTAssertEqual(map.displayedPosition(atUTF8Offset: Int.min)?.character, family)
    }

    func testEmptyWhitespaceAndPunctuationHaveNoInventedSpeechMarker() {
        for text in ["", "  \n\t", "！？", "👨‍👩‍👧‍👦"] {
            let map = SpeechDiagnosticTextMap(text: text)
            XCTAssertNil(map.matchedPosition(endingAtUTF8Offset: Int.max))
            XCTAssertNil(map.matchedPosition(endingAtUTF8Offset: 0))
            XCTAssertEqual(map.characterCount, text.count)
        }
        XCTAssertNil(SpeechDiagnosticTextMap(text: " \n").displayedPosition(atUTF8Offset: 0))
        XCTAssertNil(SpeechDiagnosticTextMap(text: "").displayedPosition(atUTF8Offset: Int.max))
    }

    func testCompactContextHasBoundedGraphemeLengthAndPreservesWordRange() throws {
        let text = String(repeating: "abcdefghij ", count: 100) + "target" + String(repeating: " 后续", count: 100)
        let map = SpeechDiagnosticTextMap(text: text)
        let endpoint = (String(repeating: "abcdefghij ", count: 100) + "target").utf8.count
        let marker = try XCTUnwrap(map.matchedPosition(endingAtUTF8Offset: endpoint))
        XCTAssertEqual(marker.word, "target")
        XCTAssertEqual(marker.wordRangeUTF8, (endpoint - 6)..<endpoint)
        XCTAssertEqual(marker.before.count, 24)
        XCTAssertEqual(marker.after.count, 24)
        XCTAssertEqual(marker.highlight, "t")
    }
}
