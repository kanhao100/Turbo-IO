import Foundation
import Combine
import RayNeoCaptions

/// Product tuning is independent of recognition-provider credentials and the manuscript.
struct PrompterTuning: Codable, Equatable {
    var minimumSimilarity = 0.60
    var minMatchedUnits = 4
    var requiredStableUpdates = 1
    var maxForwardUnits = 96
    var lookBehindUnits = 24
    var lookAheadUnits = 240
    var scrollUnitsPerSecond = 12.0
    var scrollUpdateIntervalSeconds = 0.15
    var manualAssistHoldSeconds = 1.0
    var silenceHoldSeconds = 2.0
    var recognitionEvidenceSeconds = 3.0
    var audioActivityThreshold = 0.025
    var fixedSpeed = 120
    var uniformAssistEnabled = true
    var uniformAssistHoldSeconds = 1.2
    var uniformPauseAssociationSeconds = 0.6
    var phoneSpeed = 24.0
    var nativeFontSize = 18
    var nativeWidth = 492
    var nativeLeading = 4
    var nativeCountdown = 3
    var nativeHeightGear = 3
    var nativeDepth = 1

    var followConfiguration: SpeechFollowConfiguration {
        SpeechFollowConfiguration(maxForwardUnits: maxForwardUnits, lookBehindUnits: lookBehindUnits,
            lookAheadUnits: lookAheadUnits, minMatchedUnits: minMatchedUnits,
            minimumSimilarity: minimumSimilarity, requiredStableUpdates: requiredStableUpdates)
    }
    var scrollConfiguration: SpeechScrollConfiguration {
        SpeechScrollConfiguration(maxUnitsPerSecond: scrollUnitsPerSecond,
            updateIntervalSeconds: scrollUpdateIntervalSeconds,
            manualAssistHoldSeconds: manualAssistHoldSeconds, evidenceTimeoutSeconds: recognitionEvidenceSeconds)
    }
    var nativeLayout: TeleprompterNativeLayout {
        TeleprompterNativeLayout(size: nativeFontSize, width: nativeWidth, leading: nativeLeading,
            countdown: nativeCountdown, gear: nativeHeightGear, depth: nativeDepth)
    }
    var normalized: Self {
        var result = self
        let follow = followConfiguration.normalized
        result.minimumSimilarity = follow.minimumSimilarity
        result.minMatchedUnits = follow.minMatchedUnits
        result.requiredStableUpdates = follow.requiredStableUpdates
        result.maxForwardUnits = follow.maxForwardUnits
        result.lookBehindUnits = follow.lookBehindUnits
        result.lookAheadUnits = follow.lookAheadUnits
        result.scrollUnitsPerSecond = finite(scrollUnitsPerSecond, range: 2...40, fallback: 12)
        result.scrollUpdateIntervalSeconds = finite(scrollUpdateIntervalSeconds, range: 0.10...1, fallback: 0.15)
        result.manualAssistHoldSeconds = finite(manualAssistHoldSeconds, range: 0...5, fallback: 1)
        result.silenceHoldSeconds = finite(silenceHoldSeconds, range: 0.3...6, fallback: 2)
        result.recognitionEvidenceSeconds = finite(recognitionEvidenceSeconds, range: 0.5...8, fallback: 3)
        result.audioActivityThreshold = finite(audioActivityThreshold, range: 0...0.15, fallback: 0.025)
        result.fixedSpeed = min(240, max(60, fixedSpeed))
        result.uniformAssistHoldSeconds = finite(uniformAssistHoldSeconds, range: 0...5, fallback: 1.2)
        result.uniformPauseAssociationSeconds = finite(uniformPauseAssociationSeconds, range: 0...2, fallback: 0.6)
        result.phoneSpeed = finite(phoneSpeed, range: 8...80, fallback: 24)
        result.nativeFontSize = [18, 20, 24].contains(nativeFontSize) ? nativeFontSize : 18
        result.nativeWidth = min(492, max(240, nativeWidth))
        result.nativeLeading = min(16, max(0, nativeLeading))
        result.nativeCountdown = min(10, max(0, nativeCountdown))
        result.nativeHeightGear = min(3, max(1, nativeHeightGear))
        result.nativeDepth = min(3, max(1, nativeDepth))
        return result
    }
    private func finite(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

@MainActor final class PrompterSettingsStore: ObservableObject {
    static let preferencesKey = "companion.prompter.tuning.v1"
    @Published private(set) var tuning: PrompterTuning
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tuning = Self.load(defaults: defaults)
    }
    static func load(defaults: UserDefaults = .standard) -> PrompterTuning {
        // New controls inherit recommended defaults without discarding saved tuning.
        guard let data = defaults.data(forKey: preferencesKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recommended = try? JSONEncoder().encode(PrompterTuning()),
              var fields = try? JSONSerialization.jsonObject(with: recommended) as? [String: Any] else { return PrompterTuning() }
        for (key, value) in saved { fields[key] = value }
        guard let merged = try? JSONSerialization.data(withJSONObject: fields),
              let tuning = try? JSONDecoder().decode(PrompterTuning.self, from: merged) else { return PrompterTuning() }
        return tuning.normalized
    }
    @discardableResult func save(_ next: PrompterTuning) -> Bool {
        let value = next.normalized
        guard let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: Self.preferencesKey)
        tuning = value
        return true
    }
    func update<Value>(_ keyPath: WritableKeyPath<PrompterTuning, Value>, _ value: Value) {
        var next = tuning; next[keyPath: keyPath] = value; _ = save(next)
    }
    func reset() { _ = save(PrompterTuning()) }
}
