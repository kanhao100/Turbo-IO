import XCTest
import Security
import RayNeoCaptions
@testable import RayNeoCompanion

final class CaptionBoundaryTests: XCTestCase {
    @MainActor func testSourceOnlyCannotArmUploadOrStoreKeys() throws {
        #if !COMPANION_DEVICE
        let voice = CompanionVoiceRuntime()
        let runtime = CaptionRuntime(voice: voice)
        var options = CaptionOptions(); options.region = "eastus"
        for service in CaptionService.allCases {
            options.service = service
            runtime.arm(options)
            XCTAssertEqual(runtime.phase, .idle)
            XCTAssertFalse(voice.captionOwnsVoice)
            XCTAssertFalse(runtime.save(options, newKey: "synthetic-test-only"))
            XCTAssertNotNil(runtime.error)
            XCTAssertNil(CaptionASRFactory.make(service))
        }
        #endif
    }
    @MainActor func testLaunchNeverRestoresConsentToRecordOrArms() throws {
        let suite = "caption-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = CaptionOptions(); options.region = "eastus"; options.service = .elevenLabs; options.recordAudio = true
        defaults.set(try JSONEncoder().encode(options), forKey: "companion.azureCaptions.options.v1")
        let voice = CompanionVoiceRuntime(speech: SpeechSettingsStore(defaults: defaults))
        let runtime = CaptionRuntime(voice: voice, defaults: defaults)
        XCTAssertFalse(runtime.options.recordAudio)
        XCTAssertFalse(runtime.active); XCTAssertFalse(voice.captionOwnsVoice)
        XCTAssertEqual(runtime.options.region, "eastus")
        XCTAssertEqual(runtime.options.service, .elevenLabs)
    }
    func testAzureKeysAreIsolatedByRegionAndCanBeRemoved() throws {
        let region = "ct" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var options = CaptionOptions(); options.region = region
        var other = options; other.region += "other"
        defer { try? CaptionCredentials.remove(options: options) }
        do {
            try CaptionCredentials.save("synthetic-test-only", options: options)
        } catch CaptionCredentials.StorageError.keychain(let status)
                    where status == errSecMissingEntitlement || status == errSecNotAvailable {
            // The CI simulator build is deliberately unsigned (CODE_SIGNING_ALLOWED=NO).
            // Do not replace device Keychain storage with a test-only plaintext fallback.
            throw XCTSkip("This unsigned simulator runner cannot access Keychain (OSStatus \(status)).")
        }
        XCTAssertEqual(CaptionCredentials.read(options: options), "synthetic-test-only")
        XCTAssertNil(CaptionCredentials.read(options: other))
        try CaptionCredentials.remove(options: options)
        XCTAssertNil(CaptionCredentials.read(options: options))
    }
}
