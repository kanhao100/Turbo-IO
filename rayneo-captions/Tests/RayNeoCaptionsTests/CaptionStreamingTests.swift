import XCTest
@testable import RayNeoCaptions

final class CaptionStreamingTests: XCTestCase {
    func testOldSettingsMigrateToAzureWithoutChangingSessionChoices() throws {
        let old = Data(#"{"region":"eastus","language":"zh-CN","idleSeconds":300,"maximumSeconds":3600,"recordAudio":false}"#.utf8)
        let options = try JSONDecoder().decode(CaptionOptions.self, from: old)
        XCTAssertEqual(options.service, .azure)
        XCTAssertEqual(options.credentialAccount, "eastus")
        XCTAssertEqual(options.service.keychainService, "io.turboio.companion.azure-speech.v1")
        XCTAssertEqual(options.idleSeconds, 300); XCTAssertEqual(options.maximumSeconds, 3600)
        XCTAssertEqual(options.language, "zh-CN")
    }
    func testAllServicesRoundTripAndOnlyAzureNeedsRegion() throws {
        for service in CaptionService.allCases {
            var options = CaptionOptions(); options.service = service
            if service == .aliyun { options.aliyunHost = "workspace-a.cn-beijing.maas.aliyuncs.com" }
            if service == .azure { XCTAssertThrowsError(try options.validated()); options.region = "eastus" }
            XCTAssertNoThrow(try options.validated())
            XCTAssertEqual(try JSONDecoder().decode(CaptionOptions.self, from: JSONEncoder().encode(options)), options)
            options.maximumSeconds = 0
            XCTAssertThrowsError(try options.validated())
        }
    }
    func testCredentialScopesAreSeparateAndAzureScopeIsStable() {
        XCTAssertEqual(Set(CaptionService.allCases.map(\.keychainService)).count, 4)
        var options = CaptionOptions(); options.region = " EastUS\n"
        XCTAssertEqual(options.credentialAccount, "eastus")
        options.service = .deepgram; XCTAssertEqual(options.credentialAccount, "default")
        options.service = .elevenLabs; XCTAssertEqual(options.credentialAccount, "default")
    }
    func testDeepgramRequestKeepsKeyOutOfURLAndUsesPCMFormat() throws {
        var options = CaptionOptions(); options.service = .deepgram; options.language = "zh-CN"
        let request = try CaptionStreamingAPI.request(options: options, key: "synthetic-test-only")
        let url = try XCTUnwrap(request.url)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.scheme, "wss"); XCTAssertEqual(url.host, "api.deepgram.com")
        XCTAssertEqual(url.path, "/v1/listen"); XCTAssertFalse(url.absoluteString.contains("synthetic"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token synthetic-test-only")
        XCTAssertNil(request.value(forHTTPHeaderField: "xi-api-key"))
        XCTAssertEqual(query["model"], "nova-3"); XCTAssertEqual(query["language"], "zh-CN")
        XCTAssertEqual(query["sample_rate"], "16000"); XCTAssertEqual(query["channels"], "1")
        XCTAssertEqual(query["encoding"], "linear16"); XCTAssertEqual(query["interim_results"], "true")
    }
    func testElevenLabsRequestMapsLanguagesAndAutomaticallyCommits() throws {
        for (language, code) in [("en-GB", "en"), ("en-US", "en"), ("zh-CN", "zh")] {
            var options = CaptionOptions(); options.service = .elevenLabs; options.language = language
            let request = try CaptionStreamingAPI.request(options: options, key: "synthetic-test-only")
            let url = try XCTUnwrap(request.url)
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(url.host, "api.elevenlabs.io"); XCTAssertEqual(url.path, "/v1/speech-to-text/realtime")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "synthetic-test-only")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(url.absoluteString.contains("synthetic"))
            XCTAssertEqual(query["model_id"], "scribe_v2_realtime"); XCTAssertEqual(query["language_code"], code)
            XCTAssertEqual(query["audio_format"], "pcm_16000"); XCTAssertEqual(query["commit_strategy"], "vad")
            XCTAssertEqual(query["include_timestamps"], "false")
        }
    }
    func testHeaderInjectionAndInvalidOptionsNeverCreateRequests() {
        var options = CaptionOptions(); options.service = .deepgram
        for key in ["", "short", "synthetic-key\r\nX-Other: value", String(repeating: "a", count: 513), "中文密钥中文密钥中文密钥"] {
            XCTAssertThrowsError(try CaptionStreamingAPI.request(options: options, key: key))
        }
        options.language = "arbitrary"
        XCTAssertThrowsError(try CaptionStreamingAPI.request(options: options, key: "synthetic-test-only"))
    }
    func testDeepgramFinalizesSegmentsBeforeSpeechEndpoint() throws {
        let interim = #"{"type":"Results","channel":{"alternatives":[{"transcript":"Good"}]},"is_final":false,"speech_final":false}"#
        let segment = #"{"type":"Results","channel":{"alternatives":[{"transcript":"Good morning."}]},"is_final":true,"speech_final":false}"#
        let ending = #"{"type":"Results","channel":{"alternatives":[{"transcript":"Welcome."}]},"is_final":true,"speech_final":true}"#
        XCTAssertEqual(try event(interim, .deepgram), .text("Good", final: false, utteranceEnd: false))
        XCTAssertEqual(try event(segment, .deepgram), .text("Good morning.", final: true, utteranceEnd: false))
        XCTAssertEqual(try event(ending, .deepgram), .text("Welcome.", final: true, utteranceEnd: true))
        XCTAssertEqual(try event(#"{"type":"UtteranceEnd","last_word_end":2.3}"#, .deepgram), .ignored)
    }
    func testElevenLabsCommitIsNotDuplicatedByDelayedTimestamps() throws {
        XCTAssertEqual(try event(#"{"message_type":"session_started"}"#, .elevenLabs), .ready)
        XCTAssertEqual(try event(#"{"message_type":"partial_transcript","text":"早"}"#, .elevenLabs), .text("早", final: false, utteranceEnd: false))
        XCTAssertEqual(try event(#"{"message_type":"committed_transcript","text":"早安"}"#, .elevenLabs), .text("早安", final: true, utteranceEnd: true))
        XCTAssertEqual(try event(#"{"message_type":"committed_transcript_with_timestamps","text":"早安","words":[]}"#, .elevenLabs), .ignored)
        XCTAssertEqual(try event(#"{"message_type":"committed_transcript","text":""}"#, .elevenLabs), .text("", final: true, utteranceEnd: true))
    }
    func testServiceErrorsAreSanitizedAndPermanentErrorsDoNotRetry() throws {
        for (type, expected) in [("auth_error", CaptionConnectionFailure.authentication), ("quota_exceeded", .quota),
                                 ("rate_limited", .quota), ("unaccepted_terms", .rejected), ("transcriber_error", .connection)] {
            let data = try JSONSerialization.data(withJSONObject: ["message_type": type, "error": "private upstream details"])
            XCTAssertEqual(try CaptionStreamingAPI.event(data, service: .elevenLabs), .failure(expected))
            XCTAssertFalse(expected.message.contains("private"))
        }
        XCTAssertFalse(CaptionConnectionFailure.authentication.canRetry)
        XCTAssertFalse(CaptionConnectionFailure.quota.canRetry)
        XCTAssertTrue(CaptionConnectionFailure.connection.canRetry)
        XCTAssertEqual(CaptionConnectionFailure.httpStatus(401), .authentication)
        XCTAssertEqual(CaptionConnectionFailure.httpStatus(429), .quota)
        XCTAssertEqual(CaptionConnectionFailure.httpStatus(503), .connection)
        XCTAssertEqual(try event(#"{"type":"Error","description":"secret upstream body"}"#, .deepgram), .failure(.rejected))
    }
    func testMalformedAndOversizedTranscriptsAreRejected() throws {
        XCTAssertThrowsError(try event("not JSON", .deepgram))
        XCTAssertThrowsError(try event(#"{"type":"Results"}"#, .deepgram))
        XCTAssertThrowsError(try event(#"{"message_type":"partial_transcript"}"#, .elevenLabs))
        let oversized = try JSONSerialization.data(withJSONObject: ["message_type": "committed_transcript", "text": String(repeating: "a", count: 32_769)])
        XCTAssertThrowsError(try CaptionStreamingAPI.event(oversized, service: .elevenLabs))
        XCTAssertThrowsError(try CaptionStreamingAPI.event(Data(repeating: 0, count: 262_145), service: .deepgram))
    }
    func testElevenLabsAudioIsLosslessPCMWithoutForcedCommits() throws {
        let pcm = Data((0..<3_200).map { UInt8($0 % 256) })
        let text = try CaptionStreamingAPI.elevenLabsAudio(pcm)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(value["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(value["commit"] as? Bool, false)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(value["audio_base_64"] as? String)), pcm)
    }
    func testAudioBufferPreservesOrderAcrossFrameBoundariesAndBoundsMemory() throws {
        var buffer = CaptionAudioBuffer()
        try buffer.append(Data(repeating: 1, count: 1_920)); XCTAssertNil(buffer.next())
        try buffer.append(Data(repeating: 2, count: 1_920))
        XCTAssertEqual(buffer.next(), Data(repeating: 1, count: 1_920) + Data(repeating: 2, count: 1_280))
        XCTAssertEqual(buffer.count, 640)
        buffer = CaptionAudioBuffer()
        for _ in 0..<20 { try buffer.append(Data(repeating: 0, count: 3_200)) }
        XCTAssertEqual(buffer.count, 64_000)
        XCTAssertThrowsError(try buffer.append(Data(repeating: 0, count: 320))) { XCTAssertEqual($0 as? CaptionConnectionFailure, .backpressure) }
        XCTAssertEqual(buffer.count, 64_000)
        XCTAssertThrowsError(try buffer.append(Data([1])))
        XCTAssertThrowsError(try buffer.append(Data(repeating: 0, count: 3_842)))
    }
    private func event(_ json: String, _ service: CaptionService) throws -> CaptionStreamEvent {
        try CaptionStreamingAPI.event(Data(json.utf8), service: service)
    }
}
