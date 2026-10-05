import Foundation

/// Display motion uses original graphemes, independently of the recognizer's
/// normalized matching units. These limits never select a manuscript position.
public struct SpeechScrollConfiguration: Codable, Equatable, Sendable {
    public var maxUnitsPerSecond: Double
    public var updateIntervalSeconds: Double
    public var manualAssistHoldSeconds: Double
    public var evidenceTimeoutSeconds: Double

    public init(maxUnitsPerSecond: Double = 12, updateIntervalSeconds: Double = 0.15,
                manualAssistHoldSeconds: Double = 1, evidenceTimeoutSeconds: Double = 3) {
        self.maxUnitsPerSecond = maxUnitsPerSecond
        self.updateIntervalSeconds = updateIntervalSeconds
        self.manualAssistHoldSeconds = manualAssistHoldSeconds
        self.evidenceTimeoutSeconds = evidenceTimeoutSeconds
    }

    public var normalized: Self {
        func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        return Self(maxUnitsPerSecond: bounded(maxUnitsPerSecond, to: 1...40, fallback: 12),
                    updateIntervalSeconds: bounded(updateIntervalSeconds, to: 0.05...1, fallback: 0.15),
                    manualAssistHoldSeconds: bounded(manualAssistHoldSeconds, to: 0...5, fallback: 1),
                    evidenceTimeoutSeconds: bounded(evidenceTimeoutSeconds, to: 0.2...10, fallback: 3))
    }
}

/// A confirmed speech position is a destination, never an immediate display jump.
/// Only an explicit reset (start/gesture/paragraph selection) reanchors directly.
/// Duplicate callbacks and corrections cannot buy movement time or refresh stale
/// evidence. Uncertainty discards queued motion while leaving recognition to its owner.
public struct SpeechScrollController: Sendable {
    public let configuration: SpeechScrollConfiguration
    public private(set) var displayedUTF8Offset = 0

    private let boundaries: [Int]
    private var displayedUnit = 0
    private var targetUnit = 0
    private var highestObservedUnit = 0
    private var evidenceAt: TimeInterval?
    private var lastAdvanceAt: TimeInterval?
    private var suppressedUntil: TimeInterval = -.infinity
    private var fractionalUnits = 0.0

    public init(text: String, configuration: SpeechScrollConfiguration = .init()) {
        self.configuration = configuration.normalized
        var offsets = [0], offset = 0
        for character in text {
            offset += String(character).utf8.count
            offsets.append(offset)
        }
        boundaries = offsets
    }

    /// The offset is rounded down to an original grapheme boundary. Recognition
    /// can continue throughout a manual hold and supply a fresh nearby destination.
    public mutating func reset(toUTF8Offset offset: Int, now: TimeInterval, manual: Bool = false) {
        guard now.isFinite else { return }
        displayedUnit = unit(atOrBefore: offset)
        displayedUTF8Offset = boundaries[displayedUnit]
        targetUnit = displayedUnit
        highestObservedUnit = displayedUnit
        evidenceAt = nil
        lastAdvanceAt = now
        suppressedUntil = manual ? now + configuration.manualAssistHoldSeconds : now
        fractionalUnits = 0
    }

    /// Accept only forward evidence. A backwards revision can shorten the pending
    /// destination, but cannot rewind the view or extend the previous evidence life.
    public mutating func observe(targetUTF8Offset offset: Int, now: TimeInterval) {
        guard usable(now) else { return }
        if let evidenceAt, now - evidenceAt > configuration.evidenceTimeoutSeconds {
            discardMotion(now: now)
        }
        let target = unit(atOrBefore: offset)
        if target <= highestObservedUnit {
            targetUnit = max(displayedUnit, min(targetUnit, target))
            if targetUnit == displayedUnit { fractionalUnits = 0 }
            return
        }
        highestObservedUnit = target
        targetUnit = max(displayedUnit, target)
        if evidenceAt == nil { lastAdvanceAt = now; fractionalUnits = 0 }
        evidenceAt = now
        if lastAdvanceAt == nil { lastAdvanceAt = now }
    }

    /// Stop immediately on uncertainty, silence or explicit pause. Keeping the
    /// previous highest observation prevents an old duplicate from restarting it.
    public mutating func hold(now: TimeInterval) {
        guard usable(now) else { return }
        discardMotion(now: now)
    }

    /// Each tick moves at most a short bounded frame; a delayed callback never
    /// accumulates seconds of catch-up motion. Returned positions are UTF-8 safe.
    @discardableResult public mutating func advance(now: TimeInterval) -> Int {
        guard usable(now) else { return displayedUTF8Offset }
        guard let evidenceAt, now - evidenceAt <= configuration.evidenceTimeoutSeconds else {
            discardMotion(now: now)
            return displayedUTF8Offset
        }
        guard now >= suppressedUntil else {
            lastAdvanceAt = now
            fractionalUnits = 0
            return displayedUTF8Offset
        }
        guard targetUnit > displayedUnit else {
            lastAdvanceAt = now
            fractionalUnits = 0
            return displayedUTF8Offset
        }
        guard let previous = lastAdvanceAt else { lastAdvanceAt = now; return displayedUTF8Offset }
        // Time spent in a gesture hold must not be charged to the first frame.
        let elapsed = now - max(previous, suppressedUntil)
        guard elapsed + 0.000_000_001 >= configuration.updateIntervalSeconds else { return displayedUTF8Offset }
        lastAdvanceAt = now
        let boundedElapsed = min(elapsed, min(0.3, configuration.updateIntervalSeconds * 2))
        let budget = fractionalUnits + configuration.maxUnitsPerSecond * boundedElapsed
        let step = min(targetUnit - displayedUnit, Int(floor(budget + 0.000_000_001)))
        displayedUnit += step
        displayedUTF8Offset = boundaries[displayedUnit]
        fractionalUnits = targetUnit == displayedUnit ? 0 : max(0, budget - Double(step))
        return displayedUTF8Offset
    }

    private mutating func discardMotion(now: TimeInterval) {
        targetUnit = displayedUnit
        evidenceAt = nil
        fractionalUnits = 0
        lastAdvanceAt = now
    }

    private func usable(_ now: TimeInterval) -> Bool {
        now.isFinite && (lastAdvanceAt.map { now >= $0 } ?? true)
            && (evidenceAt.map { now >= $0 } ?? true)
    }

    private func unit(atOrBefore offset: Int) -> Int {
        let bounded = min(boundaries.last ?? 0, max(0, offset))
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle] <= bounded { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}
