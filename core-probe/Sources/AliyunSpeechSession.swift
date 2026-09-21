import Foundation

/// The single Alibaba streaming transport, shared by the companion's captions,
/// conversation, and the standalone diagnostic host. Main-queue owned.
final class AliyunSpeechSession {
    enum Failure: Error {
        case configuration, authentication, rejected, connection, backpressure
        var message: String {
            switch self {
            case .configuration: return "阿里云 Host 或 Key 格式无效"
            case .authentication: return "阿里云 Key 无效或没有转写权限"
            case .rejected: return "阿里云拒绝任务，请检查额度、权限和模型"
            case .connection: return "阿里云连接或转写协议中断"
            case .backpressure: return "阿里云上传跟不上实时音频"
            }
        }
    }
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var onFailure: ((Failure) -> Void)?
    private var generation = UUID()
    private var session: URLSession?, socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?, sender: Task<Void, Never>?
    private var queue: [Data] = [], queuedBytes = 0
    private var ready = false, lastSentence = -1, sentenceFinished = false

    func start(host: String, key: String, language: String) {
        precondition(Thread.isMainThread)
        stop()
        guard let host = CloudASRHostSettings.normalize(host), (16...512).contains(key.utf8.count),
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { fail(.configuration); return }
        let token = generation, taskID = generation.uuidString.lowercased()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 7_230
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: AliyunNoRedirect(), delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: URL(string: "wss://\(host)/api-ws/v1/inference")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 262_144
        self.socket = socket; socket.resume()
        receiver = Task { @MainActor [weak self] in
            do {
                let command = try Self.startCommand(taskID: taskID, language: language)
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
                self.fail(status == 401 || status == 403 ? .authentication : .connection)
            }
        }
    }
    static func startCommand(taskID: String, language: String) throws -> String {
        let value: [String: Any] = ["header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                        "model": "qwen-audio-3.0-asr-flash-streaming",
                        "parameters": ["format": "pcm", "sample_rate": 16000, "heartbeat": true,
                                       "language_hints": [language == "zh-CN" ? "zh" : "en"]], "input": [:]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    // Internal for deterministic wire-fixture tests; never logs raw responses.
    func accept(_ data: Data, taskID: String) throws {
        guard data.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let responseID = header["task_id"] as? String else { throw ProtocolError.invalid }
        guard responseID == taskID else { return }
        switch header["event"] as? String {
        case "task-started": ready = true; onReady?(); drain()
        case "result-generated":
            let payload = object["payload"] as? [String: Any], output = payload?["output"] as? [String: Any]
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
            fail(code.contains("auth") || code.contains("apikey") ? .authentication : .rejected)
        case "task-finished": fail(.connection)
        default: break
        }
    }
    func append(_ data: Data) {
        precondition(Thread.isMainThread)
        guard socket != nil else { return }
        guard !data.isEmpty, data.count <= 3_840, data.count % 2 == 0, queuedBytes + data.count <= 64_000 else {
            fail(.backpressure); return
        }
        queue.append(data); queuedBytes += data.count; drain()
    }
    private func drain() {
        guard ready, sender == nil, let socket else { return }
        let token = generation
        sender = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    guard !self.queue.isEmpty else { self.sender = nil; return }
                    let data = self.queue.removeFirst(); self.queuedBytes -= data.count
                    try await socket.send(.data(data))
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.fail(.connection)
            }
        }
    }
    func stop() {
        generation = UUID(); receiver?.cancel(); sender?.cancel(); receiver = nil; sender = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        queue.removeAll(); queuedBytes = 0; ready = false; lastSentence = -1; sentenceFinished = false
    }
    private func fail(_ failure: Failure) { stop(); onFailure?(failure) }
    private enum ProtocolError: Error { case invalid }
}

private final class AliyunNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
