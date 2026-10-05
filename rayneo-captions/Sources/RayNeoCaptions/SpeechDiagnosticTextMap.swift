import Foundation

/// A diagnostic marker refers to the unmodified manuscript, never normalized
/// ASR text or a UTF-8 byte interpreted as a character. Indices are zero-based.
public struct SpeechDiagnosticPosition: Equatable, Sendable {
    public let characterIndex: Int
    public let character: String
    public let word: String
    public let utf8Range: Range<Int>
    public let wordRangeUTF8: Range<Int>
    public let before: String
    public let highlight: String
    public let after: String
}

/// Alignment yields an approximate end of matched content, not the exact letter
/// being pronounced. This map makes that endpoint inspectable and separately
/// exposes the display cursor. It has no effect on speech or scrolling.
public struct SpeechDiagnosticTextMap: Sendable {
    private let characters: [Character]
    private let boundaries: [Int]
    private let previousSpeechIndices: [Int?]
    private let nextVisibleIndices: [Int?]
    private let lastVisibleIndex: Int?
    private let wordRanges: [Range<Int>]
    private let words: [String]
    public var characterCount: Int { characters.count }

    public init(text: String) {
        characters = Array(text)
        var offsets = [0], offset = 0
        for character in characters {
            offset += String(character).utf8.count
            offsets.append(offset)
        }
        boundaries = offsets
        var previous: [Int?] = [nil], lastSpeech: Int?
        var ranges = characters.indices.map { $0..<($0 + 1) }
        var labels = characters.map(String.init)
        var wordCharacters = characters.map(Self.isWordCharacter)
        for index in characters.indices {
            if Self.isSpeechCharacter(characters[index]) { lastSpeech = index }
            previous.append(lastSpeech)
            if (characters[index] == "'" || characters[index] == "’"),
               index > 0, index + 1 < characters.count,
               wordCharacters[index - 1], wordCharacters[index + 1] {
                wordCharacters[index] = true
            }
        }
        previousSpeechIndices = previous
        var wordStart = 0
        while wordStart < characters.count {
            guard wordCharacters[wordStart] else { wordStart += 1; continue }
            var wordEnd = wordStart + 1
            while wordEnd < characters.count, wordCharacters[wordEnd] { wordEnd += 1 }
            let word = String(characters[wordStart..<wordEnd])
            for index in wordStart..<wordEnd {
                ranges[index] = wordStart..<wordEnd
                labels[index] = word
            }
            wordStart = wordEnd
        }
        wordRanges = ranges
        words = labels
        var next: [Int?] = Array(repeating: nil, count: characters.count + 1)
        var nextVisible: Int?, lastVisible: Int?
        for index in characters.indices.reversed() {
            if !characters[index].isWhitespace {
                nextVisible = index
                if lastVisible == nil { lastVisible = index }
            }
            next[index] = nextVisible
        }
        nextVisibleIndices = next
        lastVisibleIndex = lastVisible
    }

    /// The last original letter/digit before an alignment endpoint. A final
    /// match may consume punctuation, so showing the preceding punctuation as
    /// a newly recognized "word" would give a misleading diagnostic.
    public func matchedPosition(endingAtUTF8Offset offset: Int) -> SpeechDiagnosticPosition? {
        let bounded = min(boundaries.last ?? 0, max(0, offset))
        guard let index = previousSpeechIndices[boundaryIndex(atOrBefore: bounded)] else { return nil }
        return position(at: index)
    }

    /// The first visible original grapheme at the display cursor. An interior
    /// byte rounds down without splitting emoji or decomposed accents.
    public func displayedPosition(atUTF8Offset offset: Int) -> SpeechDiagnosticPosition? {
        guard !characters.isEmpty else { return nil }
        let boundary = boundaryIndex(atOrBefore: offset)
        guard let index = nextVisibleIndices[boundary] ?? lastVisibleIndex else { return nil }
        return position(at: index)
    }

    private func position(at index: Int) -> SpeechDiagnosticPosition {
        let wordStart = wordRanges[index].lowerBound, wordEnd = wordRanges[index].upperBound
        let character = String(characters[index])
        return SpeechDiagnosticPosition(characterIndex: index, character: character,
            word: words[index],
            utf8Range: boundaries[index]..<boundaries[index + 1],
            wordRangeUTF8: boundaries[wordStart]..<boundaries[wordEnd],
            before: String(characters[max(0, index - 24)..<index]),
            highlight: character,
            after: String(characters[(index + 1)..<min(characters.count, index + 25)]))
    }

    private func boundaryIndex(atOrBefore offset: Int) -> Int {
        let bounded = min(boundaries.last ?? 0, max(0, offset))
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle] <= bounded { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    private static func isSpeechCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        guard isSpeechCharacter(character) else { return false }
        // Han, Kana and Hangul are inspected one grapheme at a time. Expanding
        // an entire space-free Chinese sentence would hide the matched endpoint.
        return !character.unicodeScalars.contains {
            let value = $0.value
            return (0x3400...0x9FFF).contains(value) || (0x20000...0x323AF).contains(value)
                || (0x3040...0x30FF).contains(value) || (0xAC00...0xD7AF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }
    }
}
