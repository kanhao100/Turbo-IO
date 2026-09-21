import Foundation

/// Main-queue conversation orchestrator. ASR is injected independently of the
/// language model; all providers share turn assembly, cancellation and history.
final class CloudVoicePipeline {
    var log: ((String) -> Void)?
    var onEndpoint: ((UUID) -> Void)?
    var onTranscript: ((UUID, String, Bool) -> Void)?
    var onArchiveTranscript: ((UUID, String, Bool) -> Void)?
    var onText: ((UUID, String, Bool) -> Void)?
    var onError: ((UUID) -> Void)?
    var onFailureReason: ((String) -> Void)?
    var onUtteranceBegan: ((UUID, UUID) -> Void)?
    var onEmptyUtterance: ((UUID) -> Void)?
    var continuousASR = false
    var makeRecognition: (() -> VoiceRecognitionPort?)?
    var toolDefinitions: (() -> [[String: Any]])?
    var executeTool: ((String, String, UUID) async -> String)?
    private(set) var id: UUID?
    private var recognition: VoiceRecognitionPort?
    private var session: URLSession?
    private var modelTask: Task<Void, Never>?
    private var modelID: UUID?
    private var turns = SpeechTurnAssembler()
    private var singleTurnComplete = false
    private var lastTranscriptAt = -Double.infinity
    private var history: [[String: String]] = []
    private let modelKey: () -> String?
    private let makeModelSession: () -> URLSession

    init(modelKey: @escaping () -> String? = { CloudVoiceKeys.get(CloudVoiceKeys.llmService) },
         makeModelSession: (() -> URLSession)? = nil) {
        self.modelKey = modelKey
        self.makeModelSession = makeModelSession ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 135
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            return URLSession(configuration: config, delegate: NoCloudRedirect(), delegateQueue: nil)
        }
    }
    func start(id: UUID) {
        precondition(Thread.isMainThread)
        cancel(); self.id = id
        guard modelKey() != nil else { fail(id, "缺少 DeepSeek API Key，转写配置仍可用于实时字幕"); return }
        let recognizer: VoiceRecognitionPort?
        if let makeRecognition {
            recognizer = makeRecognition() // Never fall back to Alibaba if the selected provider is unavailable.
        } else {
            #if COMPANION_DEVICE
            fail(id, "转写服务尚未连接到语音流程，请重新进入语音页面"); return
            #else
            // The standalone diagnostic host retains its existing Alibaba configuration.
            guard let key = CloudVoiceKeys.get(CloudVoiceKeys.asrService),
                  let host = CloudASRHostSettings.normalize(CloudVoiceKeys.asrHost) else {
                fail(id, "缺少转写服务配置"); return
            }
            let driver = AliyunSpeechSession()
            recognizer = VoiceRecognitionPort(start: { text, endpoint, failure in
                driver.onText = text; driver.onEndpoint = endpoint; driver.onFailure = { failure($0.message) }
                driver.start(host: host, key: key, language: "zh-CN")
            }, append: { driver.append($0) }, stop: { driver.stop() })
            #endif
        }
        guard let recognizer else { fail(id, "所选转写服务配置或密钥未就绪"); return }
        session = makeModelSession(); recognition = recognizer
        recognizer.start({ [weak self] text, final in self?.recognized(text, final: final, session: id) },
                         { [weak self] in self?.endpoint(session: id) },
                         { [weak self] message in self?.fail(id, message) })
    }
    func appendPCM(_ data: Data) {
        precondition(Thread.isMainThread)
        guard id != nil, !singleTurnComplete else { return }
        recognition?.append(data)
    }
    private func recognized(_ text: String, final: Bool, session current: UUID) {
        guard id == current, !singleTurnComplete else { return }
        do {
            for event in try turns.result(text, final: final) {
                guard id == current else { return }
                switch event {
                case .began(let turn):
                    modelID = nil; modelTask?.cancel(); modelTask = nil
                    lastTranscriptAt = -Double.infinity
                    if continuousASR { onUtteranceBegan?(turn, current) }
                case .transcript(let turn, let value):
                    let responseID = continuousASR ? turn : current
                    onArchiveTranscript?(responseID, value, false)
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastTranscriptAt >= 0.25 { onTranscript?(responseID, Self.lensText(value), false); lastTranscriptAt = now }
                default: break
                }
            }
        } catch { fail(current, "识别文字或轮次超过会话上限") }
    }
    private func endpoint(session current: UUID) {
        guard id == current, !singleTurnComplete, let event = turns.endpoint() else { return }
        switch event {
        case .ended(let turn, let transcript):
            let responseID = continuousASR ? turn : current
            onArchiveTranscript?(responseID, transcript, true)
            onTranscript?(responseID, Self.lensText(transcript), true)
            guard id == current else { return }
            if !continuousASR { singleTurnComplete = true; recognition?.stop(); recognition = nil }
            onEndpoint?(responseID)
            guard id == current else { return }
            startModel(current, transcript: transcript, turnID: responseID)
        case .retracted(let turn):
            if continuousASR { onEmptyUtterance?(turn) }
            else { fail(current, "本轮识别已撤回，没有定稿文字") }
        default: break
        }
    }
    private func startModel(_ current: UUID, transcript: String, turnID: UUID? = nil) {
        guard id == current, let session, let key = modelKey() else { fail(current,"缺少模型凭证"); return }
        let responseID = turnID ?? current
        modelTask?.cancel(); modelID = responseID
        var request = URLRequest(url:URL(string:"https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let tools = toolDefinitions?() ?? []
        let allowed = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        let toolPolicy = tools.isEmpty ? "没有工具执行能力，不能声称已创建提醒、待办或执行操作。" : "仅在用户明确要求时调用提供的Codex工具，每轮最多一个。普通聊天直接回答。不得编造执行成功，不得替用户批准权限。用户要求停止朗读或换聊天话题不等于停止Codex任务。任务可后台运行；问进度用codex_status，审批请用户在Turbo IO确认。待办天气等其他工具尚未接入，不能声称执行。"
        let messages = [["role":"system","content":"你是眼镜上的中文语音助手。用纯文本回答，不用Markdown。默认简洁；用户明确要求篇幅时遵循，例如约300字。" + toolPolicy]] + history.suffix(6) + [["role":"user","content":transcript]]
        var body: [String: Any] = ["model":"deepseek-v4-flash","thinking":["type":"disabled"],"stream":true,"max_tokens":1024,"messages":messages]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto"; body["parallel_tool_calls"] = false }
        do { request.httpBody = try JSONSerialization.data(withJSONObject:body) }
        catch { fail(current,"模型请求编码失败"); return }
        modelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (bytes,response) = try await session.bytes(for:request)
                guard self.id == current, self.modelID == responseID else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudError.remote }
                self.log?("DeepSeek HTTP200；flash/thinking disabled/stream true")
                var line = Data(), text = "", received = 0
                var coalescer = AnswerDeltaCoalescer()
                var finishReason = "unreported"
                var toolCall = VoiceToolCallAccumulator()
                var done = false, reasoning = 0
                for try await byte in bytes {
                    guard self.id == current, self.modelID == responseID, !Task.isCancelled else { return }
                    received += 1; guard received <= 262144 else { throw CloudError.limit }
                    if byte != 10 { line.append(byte); guard line.count <= 32768 else { throw CloudError.limit }; continue }
                    defer { line.removeAll(keepingCapacity:true) }
                    guard let string = String(data:line,encoding:.utf8), string.hasPrefix("data:") else { continue }
                    let value = string.dropFirst(5).trimmingCharacters(in:.whitespacesAndNewlines)
                    if value == "[DONE]" { done = true; break }
                    guard let object = try JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any],
                          let choices = object["choices"] as? [[String:Any]] else { throw CloudError.invalid }
                    for choice in choices {
                        if let reason = choice["finish_reason"] as? String {
                            finishReason = ["stop","length","content_filter","tool_calls"].contains(reason) ? reason : "other"
                        }
                        let delta = choice["delta"] as? [String:Any]
                        try toolCall.append(delta?["tool_calls"])
                        if let extra = delta?["reasoning_content"] as? String { reasoning += extra.count }
                        let addition = delta?["content"] as? String ?? ""
                        text += addition
                        guard text.utf8.count <= 8192 else { throw CloudError.limit }
                        for chunk in try coalescer.append(addition,now:ProcessInfo.processInfo.systemUptime) {
                            guard self.id == current, self.modelID == responseID else { return }
                            self.onText?(responseID,chunk.text,chunk.final)
                        }
                    }
                }
                guard self.id == current, self.modelID == responseID else { return }
                guard done else { throw CloudError.invalid }
                if toolCall.present {
                    let (name, arguments) = try toolCall.validated(allowed: allowed, finishReason: finishReason)
                    guard let execute = self.executeTool, self.id == current, self.modelID == responseID, !Task.isCancelled else { throw CloudError.invalid }
                    self.log?("Codex工具提交；不记录参数/正文，不含自动审批")
                    let result = await execute(name, arguments, responseID)
                    guard self.id == current, self.modelID == responseID, !Task.isCancelled else { return }
                    let addition = (text.isEmpty ? "" : "\n") + result
                    text += addition
                    for chunk in try coalescer.append(addition, now: ProcessInfo.processInfo.systemUptime) {
                        self.onText?(responseID, chunk.text, chunk.final)
                    }
                }
                guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CloudError.invalid }
                self.log?("DeepSeek流完成 characters=\(text.count) reasoningCharacters=\(reasoning) finishReason=\(finishReason)；正文不入日志")
                self.history.append(["role":"user","content":String(transcript.prefix(1000))])
                self.history.append(["role":"assistant","content":String(text.prefix(1000))])
                self.history = Array(self.history.suffix(6))
                for chunk in try coalescer.append("",final:true,now:ProcessInfo.processInfo.systemUptime) {
                    guard self.id == current, self.modelID == responseID else { return }
                    self.onText?(responseID,chunk.text,chunk.final)
                }
            } catch { if self.id == current && self.modelID == responseID && !Task.isCancelled { self.fail(current,"模型请求或流式响应失败") } }
        }
    }
    static func lensText(_ source: String) -> String {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for char in text {
            let item = String(char)
            if result.utf8.count + item.utf8.count > 500 { return result + "…" }
            result += item
        }
        return result
    }
    func cancel(clearHistory: Bool = false) {
        precondition(Thread.isMainThread)
        id = nil; modelID = nil
        recognition?.stop(); recognition = nil
        modelTask?.cancel(); modelTask = nil
        session?.invalidateAndCancel(); session = nil
        turns = SpeechTurnAssembler(); singleTurnComplete = false; lastTranscriptAt = -Double.infinity
        if clearHistory { history.removeAll() }
    }
    private func fail(_ current: UUID, _ reason: String) {
        guard id == current else { return }
        log?("云链路失败：\(reason)；未记录服务端错误正文")
        cancel(); onFailureReason?(reason); onError?(current)
    }
    private enum CloudError: Error { case invalid, remote, limit }
}
private final class NoCloudRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
