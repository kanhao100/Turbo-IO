import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class UnifiedSpeechTests: XCTestCase {
    @MainActor func testEveryProviderWorksWithOnlyItsOwnKeyAndSeparateModelKey() throws {
        for service in SpeechService.allCases {
            let defaults = scopedDefaults(), vault = MemorySpeechCredentials(), provider = FakeSpeechProvider()
            defer { defaults.removePersistentDomain(forName: defaults.string(forKey: "test-suite")!) }
            var selected: [SpeechService] = []
            let settings = SpeechSettingsStore(defaults: defaults, credentials: vault, allowsCredentialChanges: true,
                providerFactory: { selected.append($0); return provider })
            var value = SpeechConfiguration(); value.service = service; value.region = "eastus"; value.aliyunHost = "tenant.example.aliyuncs.com"
            XCTAssertTrue(settings.save(value, asrKey: "synthetic-test-only"))
            XCTAssertTrue(settings.captionRequirements.isEmpty)
            XCTAssertEqual(settings.conversationRequirements, ["DeepSeek API Key（用于生成回答）"])
            XCTAssertEqual(vault.asr.count, 1) // No requirement for Alibaba when another provider is selected.
            XCTAssertTrue(settings.save(value, modelKey: "sk-" + "synthetic-test-only"))
            XCTAssertTrue(settings.conversationRequirements.isEmpty)
            let port = try XCTUnwrap(settings.makeConversationRecognition())
            port.start({ _, _ in }, {}, { _ in XCTFail("unexpected ASR failure") })
            XCTAssertEqual(selected, [service]); XCTAssertEqual(provider.started?.service, service)
            XCTAssertEqual(provider.key, "synthetic-test-only")
            XCTAssertEqual(vault.asr.count, 1); port.stop()
        }
    }
    @MainActor func testSwitchingProviderDoesNotReuseAnotherProvidersCredential() {
        let defaults = scopedDefaults(), vault = MemorySpeechCredentials()
        defer { defaults.removePersistentDomain(forName: defaults.string(forKey: "test-suite")!) }
        let settings = SpeechSettingsStore(defaults: defaults, credentials: vault, allowsCredentialChanges: true)
        var value = SpeechConfiguration(); value.service = .deepgram
        XCTAssertTrue(settings.save(value, asrKey: "deepgram-test-only"))
        value.service = .elevenLabs
        XCTAssertTrue(settings.save(value))
        XCTAssertFalse(settings.hasASRKey); XCTAssertFalse(settings.captionRequirements.isEmpty)
        value.service = .deepgram; XCTAssertTrue(settings.save(value)); XCTAssertTrue(settings.hasASRKey)
    }
    @MainActor func testMigratesCaptionSelectionAndPreservesAlibabaHostWithoutArming() throws {
        let defaults = scopedDefaults(), vault = MemorySpeechCredentials()
        defer { defaults.removePersistentDomain(forName: defaults.string(forKey: "test-suite")!) }
        var old = CaptionOptions(); old.service = .elevenLabs; old.region = "southeastasia"; old.recordAudio = true
        defaults.set(try JSONEncoder().encode(old), forKey: "companion.azureCaptions.options.v1")
        CloudASRHostSettings.save("tenant.example.aliyuncs.com", defaults: defaults)
        defaults.set(true, forKey: "companion.autoVoice.v1")
        let settings = SpeechSettingsStore(defaults: defaults, credentials: vault)
        XCTAssertEqual(settings.configuration.service, .elevenLabs)
        XCTAssertEqual(settings.configuration.aliyunHost, "tenant.example.aliyuncs.com")
        let voice = CompanionVoiceRuntime(speech: settings)
        let captions = CaptionRuntime(voice: voice, defaults: defaults)
        XCTAssertFalse(voice.enabled); XCTAssertFalse(captions.active); XCTAssertFalse(captions.options.recordAudio)
        XCTAssertEqual(vault.writes, 0)
    }
    @MainActor func testAlibabaOnlyUpgradeKeepsOriginalKeychainScope() {
        let defaults = scopedDefaults(), vault = MemorySpeechCredentials()
        defer { defaults.removePersistentDomain(forName: defaults.string(forKey: "test-suite")!) }
        CloudASRHostSettings.save("tenant.example.aliyuncs.com", defaults: defaults)
        let settings = SpeechSettingsStore(defaults: defaults, credentials: vault)
        let options = settings.configuration.applying()
        XCTAssertEqual(options.service, .aliyun)
        XCTAssertEqual(options.credentialService, CloudASRHostSettings.service(for: "tenant.example.aliyuncs.com"))
        XCTAssertEqual(options.credentialAccount, "user-api-key")
        XCTAssertEqual(CloudVoiceKeys.llmService, "RayNeo.CloudLLM.https.api.deepseek.com.chat.completions")
    }
    @MainActor func testBusySessionsBlockServiceAndCredentialChanges() {
        let defaults = scopedDefaults(), vault = MemorySpeechCredentials()
        defer { defaults.removePersistentDomain(forName: defaults.string(forKey: "test-suite")!) }
        let settings = SpeechSettingsStore(defaults: defaults, credentials: vault, allowsCredentialChanges: true)
        settings.isBusy = { true }
        var value = SpeechConfiguration(); value.service = .deepgram
        XCTAssertFalse(settings.save(value, asrKey: "synthetic-test-only"))
        settings.removeASR(value); settings.removeModel()
        XCTAssertEqual(vault.writes, 0); XCTAssertEqual(settings.configuration.service, .azure)
    }
    @MainActor func testSavingDoesNotStartProviderAndBothModesUseSameSelection() throws {
        let defaults = scopedDefaults(), vault = MemorySpeechCredentials(), provider = FakeSpeechProvider()
        defer { defaults.removePersistentDomain(forName: defaults.string(forKey: "test-suite")!) }
        let settings = SpeechSettingsStore(defaults: defaults, credentials: vault, allowsCredentialChanges: true,
            providerFactory: { _ in provider })
        var value = SpeechConfiguration(); value.service = .deepgram
        XCTAssertTrue(settings.save(value, asrKey: "synthetic-test-only"))
        let voice = CompanionVoiceRuntime(speech: settings)
        let captions = CaptionRuntime(voice: voice, defaults: defaults)
        XCTAssertEqual(captions.options.service, .deepgram); XCTAssertNil(provider.started)
        XCTAssertFalse(voice.enabled); XCTAssertFalse(captions.active)
        let reloaded = SpeechSettingsStore(defaults: defaults, credentials: vault)
        XCTAssertEqual(reloaded.configuration.service, .deepgram); XCTAssertTrue(reloaded.hasASRKey)
    }
    func testAllFourServicesEnforceOnlyRelevantConfiguration() throws {
        var value = SpeechConfiguration(); value.service = .deepgram
        value.region = ""; value.aliyunHost = ""
        XCTAssertNoThrow(try value.validated())
        value.service = .elevenLabs; XCTAssertNoThrow(try value.validated())
        value.service = .azure; XCTAssertThrowsError(try value.validated())
        value.region = "southeastasia"; XCTAssertNoThrow(try value.validated())
        value.service = .aliyun; XCTAssertThrowsError(try value.validated())
        value.aliyunHost = "https://example.com"; XCTAssertThrowsError(try value.validated())
        value.aliyunHost = "tenant.example.aliyuncs.com"; XCTAssertNoThrow(try value.validated())
    }
    func testSegmentFinalDoesNotEndTurnAndAllSegmentsReachModelText() throws {
        var turns = SpeechTurnAssembler()
        let start = try turns.result("How", final: false)
        guard case .began(let id)? = start.first else { return XCTFail("Missing turn") }
        XCTAssertEqual(try turns.result("How do", final: true), [.transcript(id, "How do")])
        XCTAssertEqual(try turns.result("I test this?", final: true), [.transcript(id, "How do I test this?")])
        XCTAssertEqual(turns.endpoint(), .ended(id, "How do I test this?"))
        XCTAssertNil(turns.endpoint())
    }
    func testEmptyEventsDoNotInterruptAndUnfinishedPartialIsNeverPromoted() throws {
        var turns = SpeechTurnAssembler()
        XCTAssertTrue(try turns.result("", final: false).isEmpty); XCTAssertNil(turns.endpoint())
        let start = try turns.result("draft", final: false)
        guard case .began(let id)? = start.first else { return XCTFail("Missing turn") }
        _ = try turns.result("", final: true)
        XCTAssertEqual(turns.endpoint(), .retracted(id))
    }
    func testChineseSegmentsAndTurnLimits() throws {
        var turns = SpeechTurnAssembler()
        _ = try turns.result("你好", final: true); _ = try turns.result("世界", final: true)
        guard case .ended(_, let text)? = turns.endpoint() else { return XCTFail("Missing endpoint") }
        XCTAssertEqual(text, "你好世界")
        for _ in 0..<63 { _ = try turns.result("hello", final: true); _ = turns.endpoint() }
        XCTAssertThrowsError(try turns.result("65th turn", final: false))
    }
    @MainActor func testAlibabaIgnoresHeartbeatsOldTaskAndDuplicateFinals() throws {
        let driver = AliyunSpeechSession()
        var text: [String] = [], endpoints = 0
        driver.onText = { value, _ in text.append(value) }; driver.onEndpoint = { endpoints += 1 }
        func fixture(task: String = "current", sentence: Int, value: String, final: Bool, heartbeat: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["header": ["task_id": task, "event": "result-generated"],
                "payload": ["output": ["sentence": ["sentence_id": sentence, "text": value, "sentence_end": final, "heartbeat": heartbeat]]]])
        }
        try driver.accept(fixture(task: "old", sentence: 1, value: "old", final: true), taskID: "current")
        try driver.accept(fixture(sentence: 0, value: "", final: false, heartbeat: true), taskID: "current")
        try driver.accept(fixture(sentence: 1, value: "hel", final: false), taskID: "current")
        try driver.accept(fixture(sentence: 1, value: "hello", final: true), taskID: "current")
        try driver.accept(fixture(sentence: 1, value: "hello", final: true), taskID: "current")
        XCTAssertEqual(text, ["hel", "hello"]); XCTAssertEqual(endpoints, 1)
    }
    func testAlibabaHandshakeMapsLanguageAndPCM() throws {
        let command = try AliyunSpeechSession.startCommand(taskID: "test-task", language: "en-GB")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "qwen-audio-3.0-asr-flash-streaming")
        XCTAssertEqual(parameters["format"] as? String, "pcm"); XCTAssertEqual(parameters["sample_rate"] as? Int, 16000)
        XCTAssertEqual(parameters["language_hints"] as? [String], ["en"])
    }
    private func scopedDefaults() -> UserDefaults {
        let name = "unified-speech-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(name, forKey: "test-suite"); return defaults
    }
}

final class MemorySpeechCredentials: SpeechCredentialStorage {
    var asr: [String: String] = [:], model: String?
    var writes = 0
    private func scope(_ value: SpeechConfiguration) -> String { value.applying().credentialService + "/" + value.applying().credentialAccount }
    func asrKey(_ configuration: SpeechConfiguration) -> String? { asr[scope(configuration)] }
    func saveASR(_ key: String, configuration: SpeechConfiguration) throws { writes += 1; asr[scope(configuration)] = key }
    func removeASR(_ configuration: SpeechConfiguration) throws { writes += 1; asr.removeValue(forKey: scope(configuration)) }
    func modelKey() -> String? { model }
    func saveModel(_ key: String) throws { writes += 1; model = key }
    func removeModel() throws { writes += 1; model = nil }
}

@MainActor final class FakeSpeechProvider: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    var started: CaptionOptions?, key: String?
    var audio: [Data] = [], stopCount = 0
    func start(options: CaptionOptions, key: String) { started = options; self.key = key; onReady?() }
    func append(_ pcm: Data) { audio.append(pcm) }
    func stop() { stopCount += 1 }
}
