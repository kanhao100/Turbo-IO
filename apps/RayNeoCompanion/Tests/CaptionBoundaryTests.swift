import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class CaptionBoundaryTests: XCTestCase {
    @MainActor func testSourceOnlyCannotArmUploadOrStoreKeys() throws {
        #if !COMPANION_DEVICE
        let voice = CompanionVoiceRuntime()
        let runtime = CaptionRuntime(voice: voice)
        var options = CaptionOptions(); options.region = "eastus"
        runtime.arm(options)
        XCTAssertEqual(runtime.phase, .idle)
        XCTAssertFalse(voice.captionOwnsVoice)
        XCTAssertFalse(runtime.save(options, newKey: "synthetic-test-only"))
        XCTAssertNotNil(runtime.error)
        #endif
    }
    @MainActor func testLaunchNeverRestoresConsentToRecordOrArms() throws {
        let suite = "caption-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = CaptionOptions(); options.region = "eastus"; options.recordAudio = true
        defaults.set(try JSONEncoder().encode(options), forKey: "companion.azureCaptions.options.v1")
        let voice = CompanionVoiceRuntime()
        let runtime = CaptionRuntime(voice: voice, defaults: defaults)
        XCTAssertFalse(runtime.options.recordAudio)
        XCTAssertFalse(runtime.active); XCTAssertFalse(voice.captionOwnsVoice)
        XCTAssertEqual(runtime.options.region, "eastus")
    }
    func testAzureKeysAreIsolatedByRegionAndCanBeRemoved() throws {
        let region = "caption-test-" + UUID().uuidString
        defer { try? AzureCaptionCredentials.remove(region: region) }
        try AzureCaptionCredentials.save("synthetic-test-only", region: region)
        XCTAssertEqual(AzureCaptionCredentials.read(region: region), "synthetic-test-only")
        XCTAssertNil(AzureCaptionCredentials.read(region: region + "-other"))
        try AzureCaptionCredentials.remove(region: region)
        XCTAssertNil(AzureCaptionCredentials.read(region: region))
    }
}
