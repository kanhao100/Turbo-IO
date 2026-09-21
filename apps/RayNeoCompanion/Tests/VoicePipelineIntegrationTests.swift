import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class VoicePipelineIntegrationTests: XCTestCase {
    @MainActor func testEverySelectedASRFlowsThroughEndpointModelAndStandbyWithoutAlibabaCredentials() async throws {
        for service in SpeechService.allCases {
            let suite = "voice-pipeline-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let credentials = MemorySpeechCredentials(), provider = FakeSpeechProvider()
            let settings = SpeechSettingsStore(defaults: defaults, credentials: credentials, allowsCredentialChanges: true,
                providerFactory: { selected in XCTAssertEqual(selected, service); return provider })
            var config = SpeechConfiguration(); config.service = service; config.region = "eastus"; config.aliyunHost = "tenant.example.aliyuncs.com"
            XCTAssertTrue(settings.save(config, asrKey: "synthetic-test-only", modelKey: "sk-" + "synthetic-test-only"))
            let pipeline = CloudVoicePipeline(modelKey: { credentials.model }, makeModelSession: Self.stubSession)
            pipeline.makeRecognition = { settings.makeConversationRecognition() }; pipeline.continuousASR = true
            let standby = StandbyVoiceSession(); standby.cloudEnabled = true; standby.continuousASREnabled = true
            var commands: [StandbyVoiceSession.Command] = []
            standby.send = { _, command in commands.append(command); return true }
            standby.enable(target: "test-glasses", connected: true)
            standby.receive(from: "test-glasses", type: 1, audioBytes: 0, now: 0)
            let sessionID = try XCTUnwrap(standby.cloudSessionID)
            let completed = expectation(description: "\(service) model completed")
            var finalText = ""
            pipeline.onUtteranceBegan = { standby.cloudUtteranceBegan(id: $0, session: $1, now: 1) }
            pipeline.onTranscript = { standby.cloudTranscript($1, final: $2, id: $0) }
            pipeline.onArchiveTranscript = { _, text, final in if final { finalText = text } }
            pipeline.onEndpoint = { standby.cloudEndpoint(id: $0, now: 2) }
            pipeline.onText = { id, text, final in standby.cloudText(text, final: final, id: id, now: 3); if final { completed.fulfill() } }
            pipeline.onError = { _ in XCTFail("Unexpected pipeline error") }
            pipeline.start(id: sessionID)
            XCTAssertEqual(provider.started?.service, service)
            pipeline.appendPCM(Data(repeating: 1, count: 320))
            XCTAssertEqual(provider.audio.count, 1)
            provider.onText?("How", false)
            provider.onText?("How do", true) // A stable segment must not request a model response yet.
            XCTAssertEqual(standby.phase, .recording)
            provider.onText?("I test this?", true)
            provider.onEndpoint?()
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(finalText, "How do I test this?")
            XCTAssertEqual(standby.phase, .displaying)
            XCTAssertTrue(commands.contains(.responseComplete))
            standby.receive(from: "test-glasses", type: 3, audioBytes: 16, now: 13)
            standby.tick(now: 13)
            XCTAssertEqual(standby.phase, .idle)
            XCTAssertTrue(commands.contains(.stopAudio)); XCTAssertTrue(commands.contains(.exit))
            pipeline.cancel(); XCTAssertGreaterThan(provider.stopCount, 0)
        }
    }
    @MainActor func testMissingModelKeyDoesNotStartOrRequireAnotherRecognizer() {
        let pipeline = CloudVoicePipeline(modelKey: { nil }, makeModelSession: Self.stubSession)
        var made = 0, reason = ""
        pipeline.makeRecognition = { made += 1; return nil }
        pipeline.onFailureReason = { reason = $0 }
        pipeline.start(id: UUID())
        XCTAssertEqual(made, 0); XCTAssertNil(pipeline.id)
        XCTAssertTrue(reason.contains("DeepSeek")); XCTAssertFalse(reason.contains("阿里云"))
    }
    @MainActor func testUnavailableSelectedProviderNeverFallsBackToAlibaba() {
        let pipeline = CloudVoicePipeline(modelKey: { "synthetic-test-only" }, makeModelSession: Self.stubSession)
        var reason = ""
        pipeline.makeRecognition = { nil }; pipeline.onFailureReason = { reason = $0 }
        pipeline.start(id: UUID())
        XCTAssertNil(pipeline.id); XCTAssertTrue(reason.contains("所选转写"))
    }
    @MainActor func testStoppedAndReplacedSessionRejectsLateTranscriptsAndEndpoints() {
        let pipeline = CloudVoicePipeline(modelKey: { "synthetic-test-only" }, makeModelSession: Self.stubSession)
        var oldText: ((String, Bool) -> Void)?, oldEndpoint: (() -> Void)?, emitted = 0, stopped = 0
        pipeline.makeRecognition = { VoiceRecognitionPort(start: { text, endpoint, _ in oldText = text; oldEndpoint = endpoint }, append: { _ in }, stop: { stopped += 1 }) }
        pipeline.onTranscript = { _, _, _ in emitted += 1 }; pipeline.onEndpoint = { _ in XCTFail("stale endpoint") }
        pipeline.start(id: UUID())
        let staleText = oldText, staleEnd = oldEndpoint
        pipeline.start(id: UUID())
        staleText?("late result", true); staleEnd?()
        XCTAssertEqual(emitted, 0); XCTAssertEqual(stopped, 1)
        pipeline.cancel(); oldText?("late again", true); oldEndpoint?()
        XCTAssertEqual(emitted, 0); XCTAssertEqual(stopped, 2)
    }
    @MainActor func testEmptyRecognitionDoesNotInterruptAndNewSpeechCancelsOldTurn() async {
        let pipeline = CloudVoicePipeline(modelKey: { "synthetic-test-only" }, makeModelSession: Self.stubSession)
        pipeline.continuousASR = true
        var text: ((String, Bool) -> Void)?, endpoint: (() -> Void)?
        pipeline.makeRecognition = { VoiceRecognitionPort(start: { text = $0; endpoint = $1; _ = $2 }, append: { _ in }, stop: {}) }
        var turns: [UUID] = [], answers: [UUID] = []
        pipeline.onUtteranceBegan = { turns.append($0); _ = $1 }
        let done = expectation(description: "only the new turn finishes")
        pipeline.onText = { id, _, final in if final { answers.append(id); done.fulfill() } }
        pipeline.start(id: UUID())
        text?("", false); text?("", true); endpoint?(); XCTAssertTrue(turns.isEmpty)
        text?("old question", true); endpoint?()
        // Before the old request has a chance to deliver a delta, real new text replaces it.
        text?("new question", false); text?("new question", true); endpoint?()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(turns.count, 2); XCTAssertEqual(answers, [turns.last!])
        pipeline.cancel()
    }
    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceModelStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class VoiceModelStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true } // All traffic stays in this fixture.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.absoluteString == "https://api.deepseek.com/chat/completions", request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"Fixture answer.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(stream.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
