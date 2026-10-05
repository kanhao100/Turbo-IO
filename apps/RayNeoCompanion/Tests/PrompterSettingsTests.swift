import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class PrompterSettingsTests: XCTestCase {
    @MainActor func testRecommendedDefaultsDriveBothMatchingAndScrollController() {
        withDefaults { defaults in
            let tuning = PrompterSettingsStore(defaults: defaults).tuning
            XCTAssertEqual(tuning.minimumSimilarity, 0.60)
            XCTAssertEqual(tuning.followConfiguration.normalized.minimumSimilarity, 0.60)
            XCTAssertEqual(tuning.followConfiguration.minMatchedUnits, 4)
            XCTAssertEqual(tuning.followConfiguration.requiredStableUpdates, 1)
            XCTAssertEqual(tuning.scrollConfiguration.maxUnitsPerSecond, 12)
            XCTAssertEqual(tuning.scrollConfiguration.updateIntervalSeconds, 0.15)
            XCTAssertEqual(tuning.scrollConfiguration.manualAssistHoldSeconds, 1)
            XCTAssertEqual(tuning.scrollConfiguration.evidenceTimeoutSeconds, 3)
            XCTAssertEqual(tuning.silenceHoldSeconds, 2)
            XCTAssertEqual(tuning.audioActivityThreshold, 0.025)
            XCTAssertEqual(tuning.nativeLayout, .default)
        }
    }
    @MainActor func testEveryDeveloperControlPersistsAndResetRestoresDefaults() {
        withDefaults { defaults in
            let store = PrompterSettingsStore(defaults: defaults)
            var tuned = PrompterTuning()
            tuned.minimumSimilarity = 0.51; tuned.minMatchedUnits = 8; tuned.requiredStableUpdates = 3
            tuned.maxForwardUnits = 120; tuned.lookBehindUnits = 36; tuned.lookAheadUnits = 280
            tuned.scrollUnitsPerSecond = 18; tuned.scrollUpdateIntervalSeconds = 0.25
            tuned.manualAssistHoldSeconds = 2; tuned.silenceHoldSeconds = 3
            tuned.recognitionEvidenceSeconds = 5; tuned.audioActivityThreshold = 0.05
            tuned.fixedSpeed = 180; tuned.phoneSpeed = 36
            tuned.nativeFontSize = 20; tuned.nativeWidth = 444; tuned.nativeLeading = 6
            tuned.nativeCountdown = 1; tuned.nativeHeightGear = 2; tuned.nativeDepth = 2
            XCTAssertTrue(store.save(tuned))
            XCTAssertEqual(PrompterSettingsStore.load(defaults: defaults), tuned)
            XCTAssertEqual(PrompterSettingsStore(defaults: defaults).tuning, tuned)
            store.reset()
            XCTAssertEqual(store.tuning, PrompterTuning())
            XCTAssertEqual(PrompterSettingsStore.load(defaults: defaults), PrompterTuning())
        }
    }
    @MainActor func testInvalidPersistedValuesAreNormalizedBeforeUse() throws {
        try withDefaults { defaults in
            var invalid = PrompterTuning()
            invalid.minimumSimilarity = 0; invalid.maxForwardUnits = 999; invalid.lookAheadUnits = 12
            invalid.scrollUnitsPerSecond = -2; invalid.scrollUpdateIntervalSeconds = 0
            invalid.manualAssistHoldSeconds = -1; invalid.silenceHoldSeconds = 99
            invalid.recognitionEvidenceSeconds = -3; invalid.audioActivityThreshold = -1
            invalid.fixedSpeed = 999; invalid.phoneSpeed = -20
            invalid.nativeFontSize = 99; invalid.nativeWidth = 999
            invalid.nativeLeading = -2; invalid.nativeCountdown = 99
            invalid.nativeHeightGear = -1; invalid.nativeDepth = 9
            defaults.set(try JSONEncoder().encode(invalid), forKey: PrompterSettingsStore.preferencesKey)
            let tuning = PrompterSettingsStore.load(defaults: defaults)
            XCTAssertEqual(tuning.minimumSimilarity, 0.45)
            XCTAssertEqual(tuning.maxForwardUnits, 160)
            XCTAssertEqual(tuning.lookAheadUnits, 160)
            XCTAssertEqual(tuning.scrollUnitsPerSecond, 2)
            XCTAssertEqual(tuning.scrollUpdateIntervalSeconds, 0.1)
            XCTAssertEqual(tuning.manualAssistHoldSeconds, 0)
            XCTAssertEqual(tuning.silenceHoldSeconds, 6)
            XCTAssertEqual(tuning.recognitionEvidenceSeconds, 0.5)
            XCTAssertEqual(tuning.audioActivityThreshold, 0)
            XCTAssertEqual(tuning.fixedSpeed, 240)
            XCTAssertEqual(tuning.phoneSpeed, 8)
            XCTAssertEqual(tuning.nativeFontSize, 18)
            XCTAssertEqual(tuning.nativeWidth, 492)
            XCTAssertEqual(tuning.nativeLeading, 0)
            XCTAssertEqual(tuning.nativeCountdown, 10)
            XCTAssertEqual(tuning.nativeHeightGear, 1)
            XCTAssertEqual(tuning.nativeDepth, 3)
        }
    }
    @MainActor func testCorruptStorageAndNonfiniteInputUseSafeDefaults() {
        withDefaults { defaults in
            defaults.set(Data("invalid".utf8), forKey: PrompterSettingsStore.preferencesKey)
            let store = PrompterSettingsStore(defaults: defaults)
            XCTAssertEqual(store.tuning, PrompterTuning())
            store.update(\.scrollUnitsPerSecond, .nan)
            store.update(\.silenceHoldSeconds, .infinity)
            store.update(\.audioActivityThreshold, -.infinity)
            XCTAssertEqual(store.tuning.scrollUnitsPerSecond, 12)
            XCTAssertEqual(store.tuning.silenceHoldSeconds, 2)
            XCTAssertEqual(store.tuning.audioActivityThreshold, 0.025)
            XCTAssertEqual(PrompterSettingsStore.load(defaults: defaults), store.tuning)
        }
    }
    @MainActor private func withDefaults(_ operation: (UserDefaults) throws -> Void) rethrows {
        let suite = "PrompterSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults)
    }
}
