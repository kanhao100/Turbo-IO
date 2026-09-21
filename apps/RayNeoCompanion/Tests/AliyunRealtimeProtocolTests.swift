import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class AliyunRealtimeProtocolTests: XCTestCase {
    func testBeijingAndSingaporeRequestsUseQwen3RealtimeEndpointAndHeaders() throws {
        let key = "synthetic-key-123456"
        for (host, region) in [
            ("workspace-a.cn-beijing.maas.aliyuncs.com", AliyunRealtimeRegion.chinaBeijing),
            ("workspace-a.ap-southeast-1.maas.aliyuncs.com", AliyunRealtimeRegion.singapore)
        ] {
            let request = try AliyunSpeechSession.request(host: host, key: key)
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "wss")
            XCTAssertEqual(components.host, host)
            XCTAssertEqual(components.path, "/api-ws/v1/realtime")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "model", value: "qwen3-asr-flash-realtime")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "realtime=v1")
            XCTAssertEqual(AliyunRealtimeRegion.region(for: host), region)
        }
    }

    func testRequestRejectsPublicTrialUnknownAndCrossProtocolHosts() {
        let key = "synthetic-key-123456"
        for host in ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com",
                     "trial.cn-beijing.maas.aliyuncs.com", "workspace-a.us-east-1.maas.aliyuncs.com",
                     "workspace-a.example.com", "workspace-a.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"] {
            XCTAssertThrowsError(try AliyunSpeechSession.request(host: host, key: key), host)
        }
    }

    func testSessionUpdateUsesRealtimeVADInsteadOfLegacyRunTask() throws {
        let command = try AliyunSpeechSession.sessionUpdate(language: "zh-CN", eventID: "event_test")
        let object = try json(command)
        XCTAssertEqual(object["type"] as? String, "session.update")
        XCTAssertEqual(object["event_id"] as? String, "event_test")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["modalities"] as? [String], ["text"])
        XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
        XCTAssertEqual(session["sample_rate"] as? Int, 16_000)
        XCTAssertEqual((session["input_audio_transcription"] as? [String: String])?["language"], "zh")
        let vad = try XCTUnwrap(session["turn_detection"] as? [String: Any])
        XCTAssertEqual(vad["type"] as? String, "server_vad")
        XCTAssertEqual(vad["threshold"] as? Double, 0.2)
        XCTAssertEqual(vad["silence_duration_ms"] as? Int, 400)
        XCTAssertFalse(command.contains("run-task"))
        XCTAssertFalse(command.contains("qwen-audio-3.0-asr-flash-streaming"))

        let english = try json(AliyunSpeechSession.sessionUpdate(language: "en-GB", eventID: "event_en"))
        let englishSession = try XCTUnwrap(english["session"] as? [String: Any])
        XCTAssertEqual((englishSession["input_audio_transcription"] as? [String: String])?["language"], "en")
        XCTAssertThrowsError(try AliyunSpeechSession.sessionUpdate(language: "fr-FR", eventID: "event_bad"))
    }

    func testAudioIsBase64JSONAndFinishUsesRealtimeEvent() throws {
        let pcm = Data([0, 1, 2, 3, 4, 5])
        let append = try json(AliyunSpeechSession.audioAppend(pcm, eventID: "event_audio"))
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(append["event_id"] as? String, "event_audio")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(append["audio"] as? String)), pcm)
        let finish = try json(AliyunSpeechSession.finishCommand(eventID: "event_finish"))
        XCTAssertEqual(finish["type"] as? String, "session.finish")
        XCTAssertEqual(finish["event_id"] as? String, "event_finish")
        XCTAssertThrowsError(try AliyunSpeechSession.audioAppend(Data([1]), eventID: "event_odd"))
    }

    @MainActor func testSessionUpdatedGatesAudioReadinessAndQwenEventsDriveText() throws {
        let driver = AliyunSpeechSession()
        var readyCount = 0, texts: [(String, Bool)] = [], endpoints = 0
        driver.onReady = { readyCount += 1 }
        driver.onText = { texts.append(($0, $1)) }
        driver.onEndpoint = { endpoints += 1 }

        try driver.accept(Data(#"{"type":"session.created","session":{"id":"session-1"}}"#.utf8))
        XCTAssertEqual(readyCount, 0)
        try driver.accept(Data(#"{"type":"session.updated","session":{"id":"session-1"}}"#.utf8))
        try driver.accept(Data(#"{"type":"session.updated","session":{"id":"session-1"}}"#.utf8))
        XCTAssertEqual(readyCount, 1)

        try driver.accept(Data(#"{"type":"conversation.item.input_audio_transcription.text","item_id":"item-1","text":"今天","stash":"天气不错"}"#.utf8))
        try driver.accept(Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"今天天气不错。"}"#.utf8))
        try driver.accept(Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"重复结果"}"#.utf8))
        XCTAssertEqual(texts.map(\.0), ["今天天气不错", "今天天气不错。"])
        XCTAssertEqual(texts.map(\.1), [false, true])
        XCTAssertEqual(endpoints, 1)
        driver.stop()
    }

    @MainActor func testServerAuthenticationFailureIsClassifiedWithoutRawMessage() throws {
        let driver = AliyunSpeechSession()
        var failures: [AliyunSpeechSession.Failure] = []
        driver.onFailure = { failures.append($0) }
        try driver.accept(Data(#"{"type":"error","error":{"type":"authentication_error","code":"invalid_api_key","message":"sensitive upstream details"}}"#.utf8))
        XCTAssertEqual(failures.map(\.message), [AliyunSpeechSession.Failure.authentication.message])
        XCTAssertFalse(failures[0].message.contains("sensitive"))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
