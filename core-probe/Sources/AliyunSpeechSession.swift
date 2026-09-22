import Foundation
import RayNeoCaptions

/// Qwen3 Realtime transport used only by the companion's live-subtitle path.
/// AI conversation and saved-recording transcription intentionally keep their
/// existing DashScope task protocol until they are migrated independently.
final class AliyunSpeechSession {
    static let model = AliyunCaptionModel.qwen3Realtime.rawValue

    enum Failure: Error {
        case configuration, authentication, rejected, connection, backpressure
        var message: String {
            switch self {
            case .configuration: return "阿里云 Workspace Host、地域、语言或 Key 格式无效"
            case .authentication: return "阿里云 Key 无效、地域不匹配或没有转写权限"
            case .rejected: return "阿里云拒绝会话，请检查额度、权限和模型"
            case .connection: return "阿里云连接或流式 ASR 协议中断"
            case .backpressure: return "阿里云上传跟不上实时音频"
            }
        }
    }

    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var onFailure: ((Failure) -> Void)?

    private var generation = UUID()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var ready = false
    private var completedItems: Set<String> = []
    private var completedItemOrder: [String] = []

    func start(host: String, key: String, language: String) {
        precondition(Thread.isMainThread)
        stop()
        do {
            let request = try Self.request(host: host, key: key)
            let update = try Self.sessionUpdate(language: language, eventID: Self.eventID())
            let token = generation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 7_230
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: AliyunNoRedirect(), delegateQueue: nil)
            self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 262_144
            self.socket = socket
            socket.resume()
            receiver = Task { @MainActor [weak self] in
                do {
                    try await socket.send(.string(update))
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard let self, self.generation == token else { return }
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: throw ProtocolError.invalid
                        }
                        try self.accept(data)
                    }
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    let status = (socket.response as? HTTPURLResponse)?.statusCode
                    self.fail(Self.failure(forHTTPStatus: status))
                }
            }
        } catch {
            fail(.configuration)
        }
    }

    static func request(host: String, key: String) throws -> URLRequest {
        guard let host = AliyunRealtimeRegion.normalize(host: host),
              (16...512).contains(key.utf8.count),
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ProtocolError.invalid }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/api-ws/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { throw ProtocolError.invalid }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        return request
    }

    static func sessionUpdate(language: String, eventID: String) throws -> String {
        let recognitionLanguage: String
        switch language {
        case "zh-CN": recognitionLanguage = "zh"
        case "en-GB", "en-US": recognitionLanguage = "en"
        default: throw ProtocolError.invalid
        }
        return try json([
            "event_id": eventID,
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": 16_000,
                "input_audio_transcription": ["language": recognitionLanguage],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.2,
                    "silence_duration_ms": 400
                ]
            ]
        ])
    }

    static func audioAppend(_ data: Data, eventID: String) throws -> String {
        guard !data.isEmpty, data.count <= 3_840, data.count.isMultiple(of: 2) else {
            throw ProtocolError.invalid
        }
        return try json([
            "event_id": eventID,
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
    }

    static func finishCommand(eventID: String) throws -> String {
        try json(["event_id": eventID, "type": "session.finish"])
    }

    /// Internal for deterministic wire-fixture tests; never logs raw responses.
    func accept(_ data: Data) throws {
        guard data.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              type.utf8.count <= 128 else { throw ProtocolError.invalid }
        switch type {
        case "session.created":
            break
        case "session.updated":
            guard !ready else { return }
            ready = true
            onReady?()
            drain()
        case "conversation.item.input_audio_transcription.text":
            let itemID = try Self.itemID(object)
            guard !completedItems.contains(itemID),
                  let text = object["text"] as? String,
                  let stash = object["stash"] as? String,
                  text.utf8.count + stash.utf8.count <= 32_768 else { throw ProtocolError.invalid }
            onText?(text + stash, false)
        case "conversation.item.input_audio_transcription.completed":
            let itemID = try Self.itemID(object)
            guard !completedItems.contains(itemID) else { return }
            guard let transcript = object["transcript"] as? String,
                  transcript.utf8.count <= 32_768 else { throw ProtocolError.invalid }
            rememberCompleted(itemID)
            let token = generation
            onText?(transcript, true)
            if generation == token { onEndpoint?() }
        case "conversation.item.input_audio_transcription.failed", "error":
            fail(Self.failure(forServerEvent: object))
        case "session.finished":
            // The active path never sends finish without first invalidating its
            // generation, so a live finished event means the remote ended early.
            fail(.connection)
        default:
            break
        }
    }

    func append(_ data: Data) {
        precondition(Thread.isMainThread)
        guard socket != nil else { return }
        guard !data.isEmpty, data.count <= 3_840, data.count.isMultiple(of: 2),
              queuedBytes + data.count <= 64_000 else {
            fail(.backpressure)
            return
        }
        queue.append(data)
        queuedBytes += data.count
        drain()
    }

    private func drain() {
        guard ready, sender == nil, let socket else { return }
        let token = generation
        sender = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    guard !self.queue.isEmpty else {
                        self.sender = nil
                        return
                    }
                    let data = self.queue.removeFirst()
                    self.queuedBytes -= data.count
                    let message = try Self.audioAppend(data, eventID: Self.eventID())
                    try await socket.send(.string(message))
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                self.fail(Self.failure(forHTTPStatus: status))
            }
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        close(gracefully: true)
    }

    private func close(gracefully: Bool) {
        let closingSocket = socket
        let closingSession = session
        let sendFinish = gracefully && ready
        generation = UUID()
        receiver?.cancel()
        sender?.cancel()
        receiver = nil
        sender = nil
        socket = nil
        session = nil
        queue.removeAll()
        queuedBytes = 0
        ready = false
        completedItems.removeAll()
        completedItemOrder.removeAll()

        guard let closingSocket, let closingSession else { return }
        if sendFinish, let finish = try? Self.finishCommand(eventID: Self.eventID()) {
            Task {
                try? await closingSocket.send(.string(finish))
                closingSocket.cancel(with: .normalClosure, reason: nil)
                closingSession.finishTasksAndInvalidate()
            }
        } else {
            closingSocket.cancel(with: .goingAway, reason: nil)
            closingSession.invalidateAndCancel()
        }
    }

    private func rememberCompleted(_ itemID: String) {
        completedItems.insert(itemID)
        completedItemOrder.append(itemID)
        if completedItemOrder.count > 256 {
            completedItems.remove(completedItemOrder.removeFirst())
        }
    }

    private func fail(_ failure: Failure) {
        close(gracefully: false)
        onFailure?(failure)
    }

    private static func itemID(_ object: [String: Any]) throws -> String {
        guard let itemID = object["item_id"] as? String,
              (1...256).contains(itemID.utf8.count) else { throw ProtocolError.invalid }
        return itemID
    }

    private static func failure(forHTTPStatus status: Int?) -> Failure {
        guard let status else { return .connection }
        if status == 401 || status == 403 { return .authentication }
        if (400..<500).contains(status) { return .rejected }
        return .connection
    }

    private static func failure(forServerEvent object: [String: Any]) -> Failure {
        let error = object["error"] as? [String: Any]
        let signature = [error?["type"] as? String, error?["code"] as? String]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        if signature.contains("auth") || signature.contains("api_key") ||
            signature.contains("unauthorized") || signature.contains("forbidden") ||
            signature.contains("permission") { return .authentication }
        return .rejected
    }

    private static func eventID() -> String {
        "event_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func json(_ value: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw ProtocolError.invalid }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private enum ProtocolError: Error { case invalid }
}

/// Qwen-Audio 3.1 task-protocol transport used by live subtitles. This is a
/// separate wire protocol from `AliyunSpeechSession`; selecting a model never
/// swaps only the model string on an incompatible socket.
final class AliyunTaskSpeechSession {
    static let model = AliyunCaptionModel.qwenAudio31Streaming.rawValue

    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var onFailure: ((AliyunSpeechSession.Failure) -> Void)?

    private var generation = UUID()
    private var taskID: String?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var ready = false
    private var lastSentence = -1
    private var sentenceFinished = false

    func start(host: String, key: String, language: String) {
        precondition(Thread.isMainThread)
        stop()
        do {
            let request = try Self.request(host: host, key: key)
            let taskID = Self.makeTaskID()
            let command = try Self.startCommand(taskID: taskID, language: language)
            let token = generation
            self.taskID = taskID
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 7_230
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: AliyunNoRedirect(), delegateQueue: nil)
            self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 262_144
            self.socket = socket
            socket.resume()
            receiver = Task { @MainActor [weak self] in
                do {
                    try await socket.send(.string(command))
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard let self, self.generation == token else { return }
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: throw ProtocolError.invalid
                        }
                        try self.accept(data, taskID: taskID)
                    }
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    let status = (socket.response as? HTTPURLResponse)?.statusCode
                    self.fail(Self.failure(forHTTPStatus: status))
                }
            }
        } catch {
            fail(.configuration)
        }
    }

    static func request(host: String, key: String) throws -> URLRequest {
        guard let host = AliyunRealtimeRegion.normalize(host: host),
              (16...512).contains(key.utf8.count),
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ProtocolError.invalid }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/api-ws/v1/inference"
        guard let url = components.url else { throw ProtocolError.invalid }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return request
    }

    static func startCommand(taskID: String, language: String) throws -> String {
        guard (1...128).contains(taskID.utf8.count) else { throw ProtocolError.invalid }
        let recognitionLanguage: String
        switch language {
        case "zh-CN": recognitionLanguage = "zh"
        case "en-GB", "en-US": recognitionLanguage = "en"
        default: throw ProtocolError.invalid
        }
        return try json([
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16_000,
                    "heartbeat": true,
                    "language_hints": [recognitionLanguage]
                ],
                "input": [:]
            ]
        ])
    }

    static func finishCommand(taskID: String) throws -> String {
        guard (1...128).contains(taskID.utf8.count) else { throw ProtocolError.invalid }
        return try json([
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [:]]
        ])
    }

    /// Internal for deterministic fixtures; raw upstream messages are never logged.
    func accept(_ data: Data, taskID: String) throws {
        guard data.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let responseID = header["task_id"] as? String,
              let event = header["event"] as? String,
              event.utf8.count <= 128 else { throw ProtocolError.invalid }
        guard responseID == taskID else { return }
        switch event {
        case "task-started":
            guard !ready else { return }
            ready = true
            onReady?()
            drain()
        case "result-generated":
            let payload = object["payload"] as? [String: Any]
            let output = payload?["output"] as? [String: Any]
            guard let sentence = output?["sentence"] as? [String: Any] else { throw ProtocolError.invalid }
            if sentence["heartbeat"] as? Bool == true { return }
            guard let text = sentence["text"] as? String, text.utf8.count <= 32_768,
                  let number = sentence["sentence_id"] as? NSNumber,
                  number.doubleValue == Double(number.intValue), (0...1_000_000).contains(number.intValue),
                  let final = sentence["sentence_end"] as? Bool else { throw ProtocolError.invalid }
            let index = number.intValue
            guard index >= lastSentence, !(index == lastSentence && sentenceFinished) else { return }
            if index != lastSentence { lastSentence = index; sentenceFinished = false }
            sentenceFinished = final
            let token = generation
            onText?(text, final)
            if final, generation == token { onEndpoint?() }
        case "task-failed":
            let code = (header["error_code"] as? String ?? "").lowercased()
            if code.contains("auth") || code.contains("api_key") || code.contains("apikey") ||
                code.contains("unauthorized") || code.contains("forbidden") || code.contains("permission") {
                fail(.authentication)
            } else {
                fail(.rejected)
            }
        case "task-finished":
            // Normal stop invalidates this generation before sending finish-task.
            fail(.connection)
        default:
            break
        }
    }

    func append(_ data: Data) {
        precondition(Thread.isMainThread)
        guard socket != nil else { return }
        guard !data.isEmpty, data.count <= 3_840, data.count.isMultiple(of: 2),
              queuedBytes + data.count <= 64_000 else {
            fail(.backpressure)
            return
        }
        queue.append(data)
        queuedBytes += data.count
        drain()
    }

    private func drain() {
        guard ready, sender == nil, let socket else { return }
        let token = generation
        sender = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    guard !self.queue.isEmpty else {
                        self.sender = nil
                        return
                    }
                    let data = self.queue.removeFirst()
                    self.queuedBytes -= data.count
                    try await socket.send(.data(data))
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                self.fail(Self.failure(forHTTPStatus: status))
            }
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        close(gracefully: true)
    }

    private func close(gracefully: Bool) {
        let closingSocket = socket
        let closingSession = session
        let closingTaskID = taskID
        let sendFinish = gracefully && ready
        generation = UUID()
        receiver?.cancel()
        sender?.cancel()
        receiver = nil
        sender = nil
        socket = nil
        session = nil
        taskID = nil
        queue.removeAll()
        queuedBytes = 0
        ready = false
        lastSentence = -1
        sentenceFinished = false

        guard let closingSocket, let closingSession else { return }
        if sendFinish, let closingTaskID,
           let finish = try? Self.finishCommand(taskID: closingTaskID) {
            Task {
                try? await closingSocket.send(.string(finish))
                closingSocket.cancel(with: .normalClosure, reason: nil)
                closingSession.finishTasksAndInvalidate()
            }
        } else {
            closingSocket.cancel(with: .goingAway, reason: nil)
            closingSession.invalidateAndCancel()
        }
    }

    private func fail(_ failure: AliyunSpeechSession.Failure) {
        close(gracefully: false)
        onFailure?(failure)
    }

    private static func failure(forHTTPStatus status: Int?) -> AliyunSpeechSession.Failure {
        guard let status else { return .connection }
        if status == 401 || status == 403 { return .authentication }
        if (400..<500).contains(status) { return .rejected }
        return .connection
    }

    private static func makeTaskID() -> String {
        UUID().uuidString.lowercased()
    }

    private static func json(_ value: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw ProtocolError.invalid }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private enum ProtocolError: Error { case invalid }
}

private final class AliyunNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
