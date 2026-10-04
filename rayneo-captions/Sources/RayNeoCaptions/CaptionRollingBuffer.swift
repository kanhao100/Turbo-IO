import Foundation

public enum CaptionScrollUnit: String, Codable, CaseIterable, Sendable {
    case line, word
}

public struct CaptionRollingConfiguration: Codable, Equatable, Sendable {
    public var sourceLines: Int
    public var columns: Int
    public var scrollUnit: CaptionScrollUnit

    public init(sourceLines: Int = 3, columns: Int = 28,
                scrollUnit: CaptionScrollUnit = .line) {
        self.sourceLines = sourceLines
        self.columns = columns
        self.scrollUnit = scrollUnit
    }

    public var normalized: Self {
        Self(sourceLines: min(4, max(1, sourceLines)),
             columns: min(40, max(16, columns)), scrollUnit: scrollUnit)
    }

    public var translationLines: Int { 5 - normalized.sourceLines }
}

public struct CaptionRollingSnapshot: Equatable, Sendable {
    public let sourceLines: [String]
    public let translationLines: [String]
    public let text: String

    public var sourceText: String {
        sourceLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var translationText: String {
        translationLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate init(sourceLines: [String], translationLines: [String]) {
        self.sourceLines = sourceLines
        self.translationLines = translationLines
        let rows = sourceLines + translationLines
        self.text = (rows.isEmpty ? Array(repeating: " ", count: 5) : rows)
            .joined(separator: "\n")
    }
}

/// Independent source and translation windows. A newer source draft does not
/// invalidate a translation of earlier speech. Only each channel's own sequence
/// numbers decide whether a callback is stale.
public struct CaptionRollingBuffer: Sendable {
    private var source = CaptionRollingChannel()
    private var translation = CaptionRollingChannel()

    public init() {}

    public mutating func reset() {
        source = CaptionRollingChannel()
        translation = CaptionRollingChannel()
    }

    public mutating func updateSource(_ text: String, sentence: Int, final: Bool) {
        source.update(text, sentence: sentence, final: final)
    }

    public mutating func updateTranslation(_ text: String, sentence: Int, final: Bool) {
        translation.update(text, sentence: sentence, final: final)
    }

    public mutating func appendTranslation(_ text: String, sentence: Int) {
        updateTranslation(text, sentence: sentence, final: true)
    }

    public func snapshot(configuration: CaptionRollingConfiguration,
                         sourceVisible: Bool = true,
                         translationVisible: Bool = true) -> CaptionRollingSnapshot {
        let configuration = configuration.normalized
        let sourceCount = sourceVisible ? (translationVisible ? configuration.sourceLines : 5) : 0
        let translationCount = translationVisible ? (sourceVisible ? configuration.translationLines : 5) : 0
        return CaptionRollingSnapshot(
            sourceLines: source.rows(count: sourceCount, configuration: configuration),
            translationLines: translation.rows(count: translationCount, configuration: configuration))
    }

    /// Cumulative drafts let the caller reveal a long translation in reading
    /// order instead of immediately retaining only its last visible rows.
    /// The caller owns pacing; this pure buffer has no timers or work queue.
    public static func translationSteps(_ text: String,
                                        configuration: CaptionRollingConfiguration) -> [String] {
        let configuration = configuration.normalized
        let normalized = CaptionRollingText.normalized(text)
        guard !normalized.isEmpty else { return [] }
        let characters = Array(normalized)
        let tokens = CaptionRollingText.tokens(normalized)
        var boundaries: [Int] = []
        var consumed = 0
        var layout = CaptionRollingLayout(columns: configuration.columns)
        for token in tokens {
            if configuration.scrollUnit == .line {
                boundaries.append(contentsOf: layout.append(token).map { consumed + $0 })
            } else if !token.isSpace {
                boundaries.append(consumed + token.text.count)
            }
            consumed += token.text.count
        }
        boundaries.append(characters.count)
        var result: [String] = []
        var previousBoundary = 0
        for boundary in boundaries where boundary > previousBoundary {
            let prefix = String(characters.prefix(boundary))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, result.last != prefix { result.append(prefix) }
            previousBoundary = boundary
        }
        return result
    }
}

private struct CaptionRollingChannel: Sendable {
    private var committed = CaptionRollingHistory()
    private var draft: CaptionRollingHistory?
    private var newestSentence: Int?
    private var finalizedSentence: Int?

    mutating func update(_ text: String, sentence: Int, final: Bool) {
        guard sentence >= 0,
              newestSentence.map({ sentence >= $0 }) ?? true,
              finalizedSentence.map({ sentence > $0 }) ?? true else { return }
        newestSentence = sentence
        if final {
            committed.append(text)
            draft = nil
            finalizedSentence = sentence
        } else {
            var next = committed
            next.append(text)
            draft = next
        }
    }

    func rows(count: Int, configuration: CaptionRollingConfiguration) -> [String] {
        guard count > 0 else { return [] }
        let visible = (draft ?? committed).rows(count: count, configuration: configuration)
        return visible + Array(repeating: " ", count: count - visible.count)
    }
}

/// Keeping the last five rows for every supported width bounds memory without
/// moving a completed line's wrap origin when its predecessors are discarded.
private struct CaptionRollingHistory: Sendable {
    private var layouts = (16...40).map { CaptionRollingLayout(columns: $0) }
    private var tail: [CaptionRollingToken] = []
    private var tailBytes = 0
    private var lastCharacter: Character?
    private static let tailByteLimit = 4_096

    mutating func append(_ text: String) {
        let normalized = CaptionRollingText.normalized(text)
        guard let first = normalized.first, let last = normalized.last else { return }
        var tokens = CaptionRollingText.tokens(normalized)
        if let previous = lastCharacter, CaptionRollingText.needsSeparator(previous, first) {
            tokens.insert(CaptionRollingToken(" "), at: 0)
        }
        for index in layouts.indices {
            for token in tokens { _ = layouts[index].append(token) }
        }
        for token in tokens {
            var bounded = token
            if token.bytes > Self.tailByteLimit {
                let suffix = CaptionRollingText.suffix(token.text, bytes: Self.tailByteLimit)
                bounded = CaptionRollingToken(suffix.isEmpty ? "…" : suffix)
            }
            tail.append(bounded)
            tailBytes += bounded.bytes
            while tailBytes > Self.tailByteLimit, !tail.isEmpty {
                tailBytes -= tail.removeFirst().bytes
            }
        }
        lastCharacter = last
    }

    func rows(count: Int, configuration: CaptionRollingConfiguration) -> [String] {
        if configuration.scrollUnit == .line {
            return Array(layouts[configuration.columns - 16].rows.suffix(count))
        }
        // Re-anchor only at word boundaries (one CJK grapheme is one unit).
        // Unlike line scrolling, a partially occupied oldest row is retained
        // until removing another word is necessary to fit the visible window.
        var lower = 0, upper = tail.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if wrappedTail(from: middle, columns: configuration.columns).lineCount <= count {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        if lower == tail.count, !tail.isEmpty {
            // A single word longer than the entire window cannot be retained as
            // a word. Keep its newest grapheme-wrapped rows rather than blanking
            // the channel merely because the speaker used a long identifier.
            return Array(wrappedTail(from: tail.count - 1, columns: configuration.columns).rows.suffix(count))
        }
        return wrappedTail(from: lower, columns: configuration.columns).rows
    }

    private func wrappedTail(from start: Int, columns: Int) -> CaptionRollingLayout {
        var result = CaptionRollingLayout(columns: columns)
        for token in tail.dropFirst(start) { _ = result.append(token) }
        return result
    }
}

private struct CaptionRollingToken: Sendable {
    let text: String
    let columns: Int
    let bytes: Int
    var isSpace: Bool { text == " " }

    init(_ text: String) {
        self.text = text
        self.columns = text.reduce(0) { $0 + CaptionRollingText.width($1) }
        self.bytes = text.utf8.count
    }
}

private struct CaptionRollingLayout: Sendable {
    let columns: Int
    // Four separators plus five rows of at most 76 bytes fit the 384-byte wire
    // budget. The budget is independent of which channel owns a particular row.
    private static let rowByteLimit = 76
    private(set) var rows: [String] = []
    private(set) var lineCount = 0
    private var currentColumns = 0
    private var currentBytes = 0
    private var pendingSpace = false

    /// Returns grapheme offsets within this token at which a new row began.
    mutating func append(_ token: CaptionRollingToken) -> [Int] {
        if token.isSpace {
            pendingSpace = !rows.isEmpty
            return []
        }
        guard !token.text.isEmpty else { return [] }
        var breaks: [Int] = []
        if token.columns <= columns, token.bytes <= Self.rowByteLimit {
            let separator = pendingSpace && !rows.isEmpty ? 1 : 0
            if !rows.isEmpty, !fits(columns: token.columns + separator, bytes: token.bytes + separator) {
                beginLine()
                breaks.append(0)
            }
            if rows.isEmpty { beginLine() }
            if pendingSpace { appendDirect(" ", columns: 1, bytes: 1) }
            pendingSpace = false
            appendDirect(token.text, columns: token.columns, bytes: token.bytes)
        } else {
            // Long Latin words may exceed a row; split only between graphemes.
            // A single pathological cluster over 76 bytes is represented by an
            // ellipsis because preserving it cannot satisfy the wire budget.
            for (offset, character) in token.text.enumerated() {
                let original = String(character)
                let value = original.utf8.count <= Self.rowByteLimit ? original : "…"
                let width = value == original ? CaptionRollingText.width(character) : 1
                let bytes = value.utf8.count
                let separator = pendingSpace && !rows.isEmpty ? 1 : 0
                if !rows.isEmpty, !fits(columns: width + separator, bytes: bytes + separator) {
                    beginLine()
                    breaks.append(offset)
                }
                if rows.isEmpty { beginLine() }
                if pendingSpace { appendDirect(" ", columns: 1, bytes: 1) }
                pendingSpace = false
                appendDirect(value, columns: width, bytes: bytes)
            }
        }
        return breaks
    }

    private func fits(columns extraColumns: Int, bytes extraBytes: Int) -> Bool {
        currentColumns + extraColumns <= columns && currentBytes + extraBytes <= Self.rowByteLimit
    }

    private mutating func beginLine() {
        rows.append("")
        if rows.count > 5 { rows.removeFirst() }
        // Six means "more than any visible allocation"; no lifetime counter is
        // needed, and this avoids overflow during very long conversations.
        lineCount = min(6, lineCount + 1)
        currentColumns = 0
        currentBytes = 0
        pendingSpace = false
    }

    private mutating func appendDirect(_ value: String, columns: Int, bytes: Int) {
        rows[rows.count - 1].append(value)
        currentColumns += columns
        currentBytes += bytes
    }
}

private enum CaptionRollingText {
    static func normalized(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                continue
            } else {
                if pendingSpace { result.append(" ") }
                result.append(character)
                pendingSpace = false
            }
        }
        return result
    }

    static func tokens(_ text: String) -> [CaptionRollingToken] {
        var result: [CaptionRollingToken] = []
        var word = ""
        func flushWord() {
            if !word.isEmpty { result.append(CaptionRollingToken(word)); word = "" }
        }
        for character in text {
            if character == " " || width(character) == 2 {
                flushWord()
                result.append(CaptionRollingToken(String(character)))
            } else {
                word.append(character)
            }
        }
        flushWord()
        return result
    }

    static func needsSeparator(_ previous: Character, _ next: Character) -> Bool {
        guard width(previous) == 1, width(next) == 1 else { return false }
        return !"([{‘“".contains(previous) && !",.!?;:)]}’”".contains(next)
    }

    static func suffix(_ text: String, bytes limit: Int) -> String {
        var result: [Character] = []
        var bytes = 0
        for character in text.reversed() {
            let count = String(character).utf8.count
            guard bytes + count <= limit else { break }
            result.append(character)
            bytes += count
        }
        return String(result.reversed())
    }

    static func width(_ character: Character) -> Int {
        for scalar in character.unicodeScalars {
            let value = scalar.value
            if scalar.properties.isEmojiPresentation || value == 0xFE0F ||
                (0x1100...0x115F).contains(value) || value == 0x2329 || value == 0x232A ||
                (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value) ||
                (0xF900...0xFAFF).contains(value) || (0xFE10...0xFE19).contains(value) ||
                (0xFE30...0xFE6F).contains(value) || (0xFF00...0xFF60).contains(value) ||
                (0xFFE0...0xFFE6).contains(value) || (0x20000...0x3FFFD).contains(value) {
                return 2
            }
        }
        return 1
    }
}
