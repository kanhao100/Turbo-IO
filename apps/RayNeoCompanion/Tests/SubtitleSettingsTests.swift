import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class SubtitleSettingsTests: XCTestCase {
    @MainActor func testFreshDefaultsUseRecommendedRollingWithoutEnablingTranslation() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let settings = makeStore(defaults)
        XCTAssertEqual(settings.displayLayout, .rolling)
        XCTAssertEqual(settings.rollingConfiguration, CaptionRollingConfiguration())
        XCTAssertEqual(settings.rollingConfiguration.columns, 40)
        XCTAssertEqual(settings.rollingConfiguration.englishWidthPercent, 140)
        XCTAssertEqual(settings.translationMinimumVisibleSeconds, 1.5)
        XCTAssertEqual(settings.bilingualOrder, .sourceFirst)
        XCTAssertEqual(settings.displayRetention, .untilNextSentence)
        XCTAssertEqual(settings.partialUpdateIntervalSeconds, 0)
        XCTAssertEqual(settings.lensUpdateIntervalSeconds, 0.5)
        XCTAssertEqual(settings.translationQuality, .lowLatency)
        XCTAssertFalse(settings.translationEnabled)
    }

    @MainActor func testOldDisplayPreferencesMigrateToRollingAndKeepSavedChoices() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "mode": "bilingual", "order": "translationFirst", "retention": "seconds5",
            "showLiveSourceDuringTranslation": false, "partialUpdateIntervalSeconds": 0.2
        ]), forKey: SubtitleSettingsStore.displayPreferencesKey)
        defaults.set(true, forKey: SubtitleSettingsStore.translationEnabledKey)
        let settings = makeStore(defaults)
        XCTAssertEqual(settings.displayLayout, .rolling)
        XCTAssertEqual(settings.rollingConfiguration, CaptionRollingConfiguration())
        XCTAssertEqual(settings.translationMinimumVisibleSeconds, 1.5)
        XCTAssertEqual(settings.bilingualOrder, .translationFirst)
        XCTAssertEqual(settings.displayRetention, .seconds5)
        XCTAssertEqual(settings.partialUpdateIntervalSeconds, 0.2)
        XCTAssertFalse(settings.showLiveSourceDuringTranslation)
        XCTAssertTrue(settings.translationEnabled)
    }

    @MainActor func testRollingAndSentenceChoicesSurviveReload() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let settings = makeStore(defaults)
        let configuration = CaptionRollingConfiguration(sourceLines: 4, columns: 36, scrollUnit: .word,
                                                       englishWidthPercent: 160)
        XCTAssertTrue(settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
            retention: .untilNextSentence, translationMinimumVisibleSeconds: 2.25,
            displayLayout: .rolling, rollingConfiguration: configuration))
        var restored = makeStore(defaults)
        XCTAssertEqual(restored.rollingConfiguration, configuration)
        XCTAssertEqual(restored.translationMinimumVisibleSeconds, 2.25)
        XCTAssertTrue(settings.saveDisplayPreferences(mode: .bilingual, order: .translationFirst,
            retention: .seconds3, displayLayout: .sentence))
        restored = makeStore(defaults)
        XCTAssertEqual(restored.displayLayout, .sentence)
        XCTAssertEqual(restored.rollingConfiguration, configuration)
        XCTAssertEqual(restored.translationMinimumVisibleSeconds, 2.25)
        XCTAssertFalse(restored.translationEnabled)
    }

    @MainActor func testInvalidRollingConfigurationOrHoldDoesNotOverwritePreferences() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let settings = makeStore(defaults)
        XCTAssertTrue(settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
            retention: .untilNextSentence))
        let saved = try XCTUnwrap(defaults.data(forKey: SubtitleSettingsStore.displayPreferencesKey))
        for (sourceLines, columns) in [(0, 28), (5, 28), (3, 15), (3, 41)] {
            var invalid = CaptionRollingConfiguration()
            invalid.sourceLines = sourceLines
            invalid.columns = columns
            XCTAssertFalse(settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
                retention: .untilNextSentence, rollingConfiguration: invalid))
            XCTAssertEqual(defaults.data(forKey: SubtitleSettingsStore.displayPreferencesKey), saved)
        }
        for hold in [-0.1, 5.1, Double.nan, Double.infinity] {
            XCTAssertFalse(settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
                retention: .untilNextSentence, translationMinimumVisibleSeconds: hold))
            XCTAssertEqual(defaults.data(forKey: SubtitleSettingsStore.displayPreferencesKey), saved)
        }
        for percent in [90, 145, 210] {
            var invalid = CaptionRollingConfiguration()
            invalid.englishWidthPercent = percent
            XCTAssertFalse(settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
                retention: .untilNextSentence, rollingConfiguration: invalid))
            XCTAssertEqual(defaults.data(forKey: SubtitleSettingsStore.displayPreferencesKey), saved)
        }
    }

    @MainActor func testBuild22Width40MigratesWithoutResettingUserChoices() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "mode": "bilingual", "order": "sourceFirst", "retention": "untilNextSentence",
            "displayLayout": "rolling",
            "rollingConfiguration": ["sourceLines": 3, "columns": 40, "scrollUnit": "line"]
        ]), forKey: SubtitleSettingsStore.displayPreferencesKey)
        let settings = makeStore(defaults)
        XCTAssertEqual(settings.rollingConfiguration.columns, 40)
        XCTAssertEqual(settings.rollingConfiguration.englishWidthPercent, 140)
        XCTAssertFalse(settings.translationEnabled)
    }

    @MainActor func testBuild22RecommendedWidthMigratesToDenseDefault() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "mode": "bilingual", "order": "sourceFirst", "retention": "untilNextSentence",
            "displayLayout": "rolling",
            "rollingConfiguration": ["sourceLines": 3, "columns": 28, "scrollUnit": "line"]
        ]), forKey: SubtitleSettingsStore.displayPreferencesKey)
        let settings = makeStore(defaults)
        XCTAssertEqual(settings.rollingConfiguration.columns, 40)
        XCTAssertEqual(settings.rollingConfiguration.englishWidthPercent, 140)
        XCTAssertEqual(settings.rollingConfiguration.sourceLines, 3)
    }

    @MainActor func testSavedRollingBoundsAreNormalizedOnRead() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "mode": "bilingual", "order": "sourceFirst", "retention": "untilNextSentence",
            "displayLayout": "rolling", "translationMinimumVisibleSeconds": 8,
            "rollingConfiguration": ["sourceLines": 9, "columns": 7, "scrollUnit": "line"]
        ]), forKey: SubtitleSettingsStore.displayPreferencesKey)
        let settings = makeStore(defaults)
        XCTAssertEqual(settings.rollingConfiguration.sourceLines, 4)
        XCTAssertEqual(settings.rollingConfiguration.columns, 16)
        XCTAssertEqual(settings.translationMinimumVisibleSeconds, 5)
    }

    private var defaultsSuite = ""
    private func isolatedDefaults() -> UserDefaults {
        defaultsSuite = "SubtitleSettingsTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: defaultsSuite)!
    }
    @MainActor private func makeStore(_ defaults: UserDefaults) -> SubtitleSettingsStore {
        SubtitleSettingsStore(defaults: defaults, credentials: EmptyCredentials(), allowsChanges: true)
    }
    private struct EmptyCredentials: SubtitleCredentialStorage {
        func key(for options: CaptionOptions) -> String? { nil }
        func save(_ key: String, for options: CaptionOptions) throws {}
        func remove(for options: CaptionOptions) throws {}
    }
}
