import Foundation

/// Distances are counted in normalized letters/digits (one Han character is
/// one unit), not words or bytes. Defaults favor holding the page over jumping.
public struct SpeechFollowConfiguration: Codable, Equatable, Sendable {
    public var maxForwardUnits: Int
    public var lookBehindUnits: Int
    public var lookAheadUnits: Int
    public var minMatchedUnits: Int
    public var minimumSimilarity: Double
    public var requiredStableUpdates: Int

    public init(maxForwardUnits: Int = 64, lookBehindUnits: Int = 24,
                lookAheadUnits: Int = 160, minMatchedUnits: Int = 6,
                minimumSimilarity: Double = 0.8, requiredStableUpdates: Int = 2) {
        self.maxForwardUnits = maxForwardUnits
        self.lookBehindUnits = lookBehindUnits
        self.lookAheadUnits = lookAheadUnits
        self.minMatchedUnits = minMatchedUnits
        self.minimumSimilarity = minimumSimilarity
        self.requiredStableUpdates = requiredStableUpdates
    }

    public var normalized: Self {
        let forward = min(160, max(12, maxForwardUnits))
        return Self(maxForwardUnits: forward,
                    lookBehindUnits: min(80, max(8, lookBehindUnits)),
                    lookAheadUnits: min(400, max(forward, lookAheadUnits)),
                    minMatchedUnits: min(20, max(4, minMatchedUnits)),
                    minimumSimilarity: minimumSimilarity.isFinite
                        ? min(0.98, max(0.45, minimumSimilarity)) : 0.8,
                    requiredStableUpdates: min(4, max(1, requiredStableUpdates)))
    }
}

public enum SpeechFollowState: String, Codable, Sendable {
    case waiting, following, uncertain, paused, finished
}

public struct SpeechFollowUpdate: Equatable, Sendable {
    public let state: SpeechFollowState
    /// End of confirmed spoken content in the unmodified manuscript. Always a
    /// grapheme boundary; the last match also consumes trailing punctuation.
    public let confirmedUTF8Offset: Int
    public let candidateUTF8Offset: Int?
    public let similarity: Double
    public let shouldMove: Bool
}

/// Pure text alignment for a manuscript-led speech. Partial callbacks replace
/// the current utterance; final callbacks append a bounded recent context.
/// Recognition inaccuracies/ad-libbing hold the anchor. Automatic movement is
/// forward only and local; gestures assist the anchor without pausing listening.
///
/// This cannot identify the speaker. Another person reading the next manuscript
/// phrase can match it. The audio layer must also discard callbacks from an old
/// session; this API can reject identical queued callbacks, not infer their age.
public struct SpeechScriptFollower: Sendable {
    public let text: String
    public let configuration: SpeechFollowConfiguration
    public private(set) var confirmedUTF8Offset: Int = 0
    public private(set) var state: SpeechFollowState

    private let source: [SpeechScriptUnit]
    private let boundaries: [Int]
    private var confirmedUnit = 0
    /// A deliberate gesture/paragraph selection provides a stronger local
    /// starting prior than speech alone. It expires on the first confirmation.
    private var assistedUnit: Int?
    private var committed: [String] = []
    private var pending: SpeechScriptMatch?
    private var stableUpdates = 0
    private var candidateUTF8Offset: Int?
    private var similarity = 0.0
    private var lastInput: [String] = []
    private var lastFinal: [String] = []
    private var blockedInputs: [[String]] = []

    public init(text: String, configuration: SpeechFollowConfiguration = .init()) {
        self.text = text
        self.configuration = configuration.normalized
        source = SpeechScriptText.sourceUnits(text)
        var offsets = [0]
        var offset = 0
        for character in text {
            offset += String(character).utf8.count
            offsets.append(offset)
        }
        boundaries = offsets
        state = source.isEmpty ? .finished : .waiting
        if source.isEmpty { confirmedUTF8Offset = text.utf8.count }
    }

    /// A final phrase with at least twice the minimum evidence and >= 90%
    /// similarity can confirm immediately. Other results need new, overlapping
    /// forward evidence. Repeating an identical callback never adds evidence.
    @discardableResult
    public mutating func recognize(_ text: String, final: Bool) -> SpeechFollowUpdate {
        let input = SpeechScriptText.normalized(text)
        if state == .paused {
            // Listening may continue during explicit pause. None of that
            // speech is evidence to advance immediately upon resuming.
            if !input.isEmpty {
                lastInput = input
                if final { lastFinal = input }
            }
            return snapshot()
        }
        guard state != .finished else { return snapshot() }
        guard !input.isEmpty else { return snapshot() }
        if let blocked = blockedInputs.firstIndex(of: input) {
            blockedInputs.remove(at: blocked)
            return snapshot()
        }
        // The first fresh non-duplicate callback clears the short-lived gesture
        // barrier. A later rehearsal of exactly the same sentence is valid.
        blockedInputs.removeAll()
        if final && input == lastFinal { return snapshot() }
        let changed = input != lastInput
        if !changed && !final { return snapshot() }
        // A correction of the same-length partial is a revised hypothesis,
        // not newly spoken evidence. A new final segment may extend the recent
        // context even when its own length equals the preceding segment.
        let newSpeech = input.count > lastInput.count
            || (final && !committed.isEmpty && changed)

        let limit = max(configuration.minMatchedUnits * 2,
                        min(48, configuration.lookBehindUnits))
        let combined = committed + input
        let removed = max(0, combined.count - limit)
        let query = Array(combined.suffix(limit))
        let newStart = max(0, committed.count - removed)
        let match = findMatch(query, newStart: newStart)
        lastInput = input
        if final {
            lastFinal = input
            // An interruption must not poison the context used when the
            // speaker returns to the manuscript.
            // Small final fragments may contain less than the minimum matching
            // evidence. Preserve them until enough context is available; a
            // full-length unmatched utterance clears interruption/ad-lib text.
            committed = match == nil && query.count >= configuration.minMatchedUnits
                ? [] : Array(combined.suffix(limit))
        }

        guard let match else {
            pending = nil
            stableUpdates = 0
            candidateUTF8Offset = nil
            similarity = 0
            state = .uncertain
            return snapshot()
        }
        candidateUTF8Offset = offset(after: match.end)
        similarity = match.similarity
        // A repeated nearby line is readable evidence, but cannot rewind or
        // jump to a later occurrence of a repeated phrase.
        guard match.end > confirmedUnit else {
            pending = nil
            stableUpdates = 0
            state = .following
            return snapshot()
        }

        if changed && newSpeech {
            if let previous = pending,
               match.end > previous.end,
               min(match.end, previous.end) - max(match.start, previous.start)
                    >= configuration.minMatchedUnits {
                stableUpdates = min(configuration.requiredStableUpdates, stableUpdates + 1)
            } else if pending == nil || match.end != pending?.end || match.start != pending?.start {
                stableUpdates = 1
            }
        }
        pending = match
        let strongFinal = final && match.matches >= configuration.minMatchedUnits * 2
            && match.similarity >= max(0.9, configuration.minimumSimilarity)
        guard strongFinal || stableUpdates >= configuration.requiredStableUpdates else {
            state = .uncertain
            return snapshot()
        }

        confirmedUnit = match.end
        assistedUnit = nil
        confirmedUTF8Offset = offset(after: confirmedUnit)
        state = confirmedUnit == source.count ? .finished : .following
        // Keep the alignment for overlap, but the next movement needs fresh
        // evidence; an old count must not confirm a later recognizer revision.
        stableUpdates = 1
        return snapshot(shouldMove: true)
    }

    /// Swiping or choosing a paragraph establishes a new anchor. It is an aid
    /// to automatic following and does not switch into a manual-only mode.
    @discardableResult
    public mutating func assist(toUTF8Offset offset: Int) -> SpeechFollowUpdate {
        let wasPaused = state == .paused
        let previous = confirmedUTF8Offset
        let bounded = min(text.utf8.count, max(0, offset))
        confirmedUTF8Offset = boundaries.last(where: { $0 <= bounded }) ?? 0
        confirmedUnit = source.prefix(while: { $0.endUTF8 <= confirmedUTF8Offset }).count
        assistedUnit = confirmedUnit
        clearEvidence()
        state = wasPaused ? .paused : (confirmedUnit == source.count ? .finished : .waiting)
        return snapshot(shouldMove: previous != confirmedUTF8Offset)
    }

    @discardableResult
    public mutating func pause() -> SpeechFollowUpdate {
        clearEvidence()
        state = .paused
        return snapshot()
    }

    @discardableResult
    public mutating func resume() -> SpeechFollowUpdate {
        clearEvidence()
        state = confirmedUnit == source.count ? .finished : .waiting
        return snapshot()
    }

    /// Use when recognition restarts or audio was interrupted. Preserves the
    /// reading position and an explicit pause, while requiring fresh evidence.
    @discardableResult
    public mutating func resetRecognitionEvidence() -> SpeechFollowUpdate {
        let wasPaused = state == .paused
        clearEvidence()
        state = wasPaused ? .paused : (confirmedUnit == source.count ? .finished : .waiting)
        return snapshot()
    }

    private mutating func clearEvidence() {
        for value in [lastInput, lastFinal] where !value.isEmpty && !blockedInputs.contains(value) {
            blockedInputs.append(value)
        }
        // Fingerprints reject queued identical callbacks immediately after a
        // gesture/resume, and stay bounded even in a long rehearsal.
        blockedInputs = Array(blockedInputs.suffix(4))
        committed = []
        lastInput = []
        lastFinal = []
        pending = nil
        stableUpdates = 0
        candidateUTF8Offset = nil
        similarity = 0
    }

    private func snapshot(shouldMove: Bool = false) -> SpeechFollowUpdate {
        SpeechFollowUpdate(state: state, confirmedUTF8Offset: confirmedUTF8Offset,
                           candidateUTF8Offset: candidateUTF8Offset,
                           similarity: similarity, shouldMove: shouldMove)
    }

    private func offset(after unit: Int) -> Int {
        if unit >= source.count { return text.utf8.count }
        return unit > 0 ? source[unit - 1].endUTF8 : 0
    }

    private func findMatch(_ query: [String], newStart: Int) -> SpeechScriptMatch? {
        guard query.count >= configuration.minMatchedUnits,
              Set(query).count >= 3 else { return nil }
        let lower = max(0, confirmedUnit - configuration.lookBehindUnits)
        let upper = min(source.count, confirmedUnit + configuration.lookAheadUnits)
        let manuscript = Array(source[lower..<upper].map(\.value))
        guard !manuscript.isEmpty else { return nil }
        // Semiglobal edit alignment permits punctuation/case normalization,
        // recognizer substitutions, omissions and inserted filler words.
        var previous = (0...manuscript.count).map {
            SpeechScriptCell(cost: 0, start: $0, matches: 0, newMatches: 0)
        }
        for (index, character) in query.enumerated() {
            var row = [SpeechScriptCell(cost: index + 1, start: 0, matches: 0, newMatches: 0)]
            for column in 1...manuscript.count {
                let equal = character == manuscript[column - 1]
                var diagonal = previous[column - 1]
                diagonal.cost += equal ? 0 : 1
                if equal {
                    diagonal.matches += 1
                    if index >= newStart { diagonal.newMatches += 1 }
                }
                var insertion = previous[column]
                insertion.cost += 1
                var deletion = row[column - 1]
                deletion.cost += 1
                let best = [diagonal, insertion, deletion].min {
                    if $0.cost != $1.cost { return $0.cost < $1.cost }
                    if $0.newMatches != $1.newMatches { return $0.newMatches > $1.newMatches }
                    return $0.matches > $1.matches
                }!
                row.append(best)
            }
            previous = row
        }
        let newCount = query.count - newStart
        let neededNew = max(2, Int(ceil(Double(min(newCount, configuration.minMatchedUnits))
                                      * configuration.minimumSimilarity)))
        var candidates: [SpeechScriptMatch] = []
        let maxStart = confirmedUnit + min(24, configuration.maxForwardUnits / 3)
        for column in 1...manuscript.count {
            let cell = previous[column]
            let start = lower + cell.start
            let end = lower + column
            let span = end - start
            let similarity = 1 - Double(cell.cost) / Double(max(query.count, span))
            guard span > 0, start <= maxStart,
                  end <= confirmedUnit + configuration.maxForwardUnits,
                  cell.matches >= configuration.minMatchedUnits,
                  cell.newMatches >= neededNew,
                  similarity >= configuration.minimumSimilarity else { continue }
            candidates.append(SpeechScriptMatch(start: start, end: end,
                                                matches: cell.matches, similarity: similarity))
        }
        candidates.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.matches != $1.matches { return $0.matches > $1.matches }
            return abs($0.end - confirmedUnit) < abs($1.end - confirmedUnit)
        }
        guard let best = candidates.first else { return nil }
        if let anchor = assistedUnit {
            // A selected paragraph can intentionally repeat an earlier one.
            // Resolve only near-exact starts at this explicit anchor (at most
            // two omitted normalized units), never a distant occurrence. All
            // normal length, similarity and forward-distance guards still apply.
            let anchored = candidates.filter {
                $0.start >= anchor && $0.start <= anchor + 2 && $0.end > anchor
                    && $0.similarity >= best.similarity - 0.04
            }.min {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
                return $0.matches > $1.matches
            }
            if let anchored { return anchored }
        }
        // Similar alignments to different occurrences are unresolved evidence,
        // even when a nearest occurrence looks tempting. Minor endpoint edits
        // within one occurrence are not separate interpretations.
        let separation = max(4, query.count / 2)
        guard !candidates.dropFirst().contains(where: {
            abs($0.start - best.start) >= separation
                && abs($0.end - best.end) >= separation
                && $0.similarity >= best.similarity - 0.04
        }) else { return nil }
        return best
    }
}

private struct SpeechScriptUnit: Sendable {
    let value: String
    let endUTF8: Int
}

private struct SpeechScriptMatch: Sendable {
    let start: Int
    let end: Int
    let matches: Int
    let similarity: Double
}

private struct SpeechScriptCell {
    var cost: Int
    var start: Int
    var matches: Int
    var newMatches: Int
}

private enum SpeechScriptText {
    static func normalized(_ text: String) -> [String] {
        sourceUnits(text).map(\.value)
    }

    static func sourceUnits(_ text: String) -> [SpeechScriptUnit] {
        var result: [SpeechScriptUnit] = []
        var offset = 0
        for character in text {
            let original = String(character)
            offset += original.utf8.count
            let folded = original.precomposedStringWithCompatibilityMapping
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                         locale: Locale(identifier: "en_US_POSIX"))
            for scalar in folded.unicodeScalars {
                guard CharacterSet.letters.contains(scalar)
                        || CharacterSet.decimalDigits.contains(scalar) else { continue }
                result.append(SpeechScriptUnit(value: String(scalar), endUTF8: offset))
            }
        }
        return result
    }
}
