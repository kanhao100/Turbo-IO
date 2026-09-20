import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class CaptionSocketTests: XCTestCase {
    @MainActor func testElevenLabsWaitsForSessionBeforeSendingAudio() async throws {
        let socket = FakeCaptionSocket()
        let provider = WebSocketCaptionASR(service: .elevenLabs, makeSocket: { _ in socket })
        defer { provider.stop() }
        var options = CaptionOptions(); options.service = .elevenLabs
        let ready = expectation(description: "session ready"), sent = expectation(description: "audio sent")
        provider.onReady = { ready.fulfill() }
        provider.onFailure = { XCTFail("Unexpected failure: \($0)") }
        let pcm = Data(repeating: 7, count: 3_200)
        socket.onSend = { message in
            guard case .string(let text) = message,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let encoded = object["audio_base_64"] as? String else { XCTFail("Expected JSON audio"); return }
            XCTAssertEqual(Data(base64Encoded: encoded), pcm)
            sent.fulfill()
        }
        provider.start(options: options, key: "synthetic-test-only")
        provider.append(pcm)
        XCTAssertTrue(socket.sent.isEmpty)
        socket.emit(#"{"message_type":"session_started"}"#)
        await fulfillment(of: [ready, sent], timeout: 2)
    }
    @MainActor func testDeepgramSendsBinaryPCMAndDeliversInterimAndFinal() async {
        let socket = FakeCaptionSocket()
        let provider = WebSocketCaptionASR(service: .deepgram, makeSocket: { _ in socket })
        defer { provider.stop() }
        var options = CaptionOptions(); options.service = .deepgram
        let sent = expectation(description: "binary audio"), texts = expectation(description: "two text events")
        texts.expectedFulfillmentCount = 2
        var received: [String] = [], finals: [Bool] = []
        let pcm = Data(repeating: 3, count: 3_200)
        socket.onSend = { message in
            guard case .data(let value) = message else { XCTFail("Expected raw PCM"); return }
            XCTAssertEqual(value, pcm); sent.fulfill()
        }
        provider.onText = { text, final in received.append(text); finals.append(final); texts.fulfill() }
        provider.onFailure = { XCTFail("Unexpected failure: \($0)") }
        provider.start(options: options, key: "synthetic-test-only"); provider.append(pcm)
        socket.emit(#"{"type":"Results","channel":{"alternatives":[{"transcript":"hel"}]},"is_final":false}"#)
        socket.emit(#"{"type":"Results","channel":{"alternatives":[{"transcript":"hello"}]},"is_final":true,"speech_final":false}"#)
        await fulfillment(of: [sent, texts], timeout: 2)
        XCTAssertEqual(received, ["hel", "hello"]); XCTAssertEqual(finals, [false, true])
    }
    @MainActor func testLateResultFromReplacedSocketCannotUpdateNewSession() async {
        let old = FakeCaptionSocket(), current = FakeCaptionSocket()
        old.holdReceiveOnClose = true
        let waiting = expectation(description: "old receive in flight")
        old.onReceive = { waiting.fulfill() }
        var created = 0
        let provider = WebSocketCaptionASR(service: .elevenLabs, makeSocket: { _ in
            created += 1; return created == 1 ? old : current
        })
        defer { provider.stop() }
        var options = CaptionOptions(); options.service = .elevenLabs
        let text = expectation(description: "new result"), stale = expectation(description: "no stale callback")
        stale.isInverted = true
        provider.onText = { value, _ in if value == "new" { text.fulfill() } else { stale.fulfill() } }
        provider.onFailure = { _ in stale.fulfill() }
        provider.start(options: options, key: "synthetic-test-only")
        await fulfillment(of: [waiting], timeout: 2)
        provider.start(options: options, key: "synthetic-test-only")
        XCTAssertTrue(old.closed)
        old.emit(#"{"message_type":"committed_transcript","text":"old"}"#)
        current.emit(#"{"message_type":"session_started"}"#)
        current.emit(#"{"message_type":"committed_transcript","text":"new"}"#)
        await fulfillment(of: [text, stale], timeout: 0.2)
    }
    @MainActor func testHandshakeBufferOverflowStopsAndDropsQueuedAudio() {
        let socket = FakeCaptionSocket()
        let provider = WebSocketCaptionASR(service: .elevenLabs, makeSocket: { _ in socket })
        var options = CaptionOptions(); options.service = .elevenLabs
        var failures: [CaptionConnectionFailure] = []
        provider.onFailure = { failures.append($0) }
        provider.start(options: options, key: "synthetic-test-only")
        for _ in 0..<21 { provider.append(Data(repeating: 0, count: 3_200)) }
        XCTAssertEqual(failures, [.backpressure]); XCTAssertTrue(socket.closed); XCTAssertTrue(socket.sent.isEmpty)
        provider.append(Data(repeating: 0, count: 3_200))
        XCTAssertEqual(failures.count, 1); XCTAssertTrue(socket.sent.isEmpty)
    }
    @MainActor func testAuthenticationErrorStopsWithoutPassingRawServerText() async {
        let socket = FakeCaptionSocket()
        let provider = WebSocketCaptionASR(service: .elevenLabs, makeSocket: { _ in socket })
        defer { provider.stop() }
        var options = CaptionOptions(); options.service = .elevenLabs
        let failure = expectation(description: "auth rejected")
        provider.onFailure = { value in XCTAssertEqual(value, .authentication); failure.fulfill() }
        provider.start(options: options, key: "synthetic-test-only")
        socket.emit(#"{"message_type":"auth_error","error":"sensitive upstream details"}"#)
        await fulfillment(of: [failure], timeout: 2)
        XCTAssertTrue(socket.closed)
    }
}

@MainActor private final class FakeCaptionSocket: CaptionSocket {
    var httpStatus: Int? = 101
    var sent: [URLSessionWebSocketTask.Message] = []
    var closed = false, holdReceiveOnClose = false
    var onSend: ((URLSessionWebSocketTask.Message) -> Void)?, onReceive: (() -> Void)?
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var waiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard !closed else { throw CancellationError() }
        sent.append(message); onSend?(message)
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !messages.isEmpty { return messages.removeFirst() }
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiting = $0; onReceive?() }
    }
    func emit(_ json: String) {
        if let continuation = waiting { waiting = nil; continuation.resume(returning: .string(json)) }
        else { messages.append(.string(json)) }
    }
    func close() {
        closed = true
        if !holdReceiveOnClose { waiting?.resume(throwing: CancellationError()); waiting = nil }
    }
}
