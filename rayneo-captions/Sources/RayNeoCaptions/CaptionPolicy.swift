import Foundation

public enum CaptionFailure: Error { case invalidConfiguration, limit, corruptArchive, closed }

public enum AliyunCaptionModel: String, Codable, CaseIterable {
    case qwenAudio31Streaming = "qwen-audio-3.1-asr-flash-streaming"
    case qwen3Realtime = "qwen3-asr-flash-realtime"

    public var name: String {
        switch self {
        case .qwenAudio31Streaming: return "Qwen-Audio 3.1 Streaming（推荐）"
        case .qwen3Realtime: return "Qwen3 Realtime（兼容 / 实验）"
        }
    }

    public var detail: String {
        switch self {
        case .qwenAudio31Streaming:
            return "Task WebSocket · binary PCM · 支持时间戳与后续热词/上下文扩展"
        case .qwen3Realtime:
            return "Realtime Session API · Base64 JSON · 服务端 VAD"
        }
    }
}

public enum CaptionService: String, Codable, CaseIterable {
    case azure, deepgram, aliyun
    case elevenLabs = "elevenlabs"
    case selfHostedQwen = "self-hosted-qwen"

    public var name: String {
        switch self {
        case .azure: return "Azure Speech"
        case .deepgram: return "Deepgram"
        case .elevenLabs: return "ElevenLabs"
        case .aliyun: return "阿里云流式 ASR"
        case .selfHostedQwen: return "自建 Qwen3-ASR"
        }
    }
    public var model: String {
        switch self {
        case .azure: return "Azure Speech"
        case .deepgram: return "Nova-3"
        case .elevenLabs: return "Scribe v2 Realtime"
        case .aliyun: return AliyunCaptionModel.qwenAudio31Streaming.rawValue
        case .selfHostedQwen: return "Qwen3-ASR OpenAI Realtime"
        }
    }
    public var keychainService: String {
        switch self {
        // Preserve the original Azure namespace so upgrading does not lose saved keys.
        case .azure: return "io.turboio.companion.azure-speech.v1"
        case .deepgram: return "io.turboio.companion.deepgram.v1"
        case .elevenLabs: return "io.turboio.companion.elevenlabs.v1"
        case .aliyun: return "RayNeo.CloudASR.https."
        case .selfHostedQwen: return "io.turboio.companion.self-hosted-qwen.v1"
        }
    }
}

/// Explicit recognition-language intent. `automatic` is not represented by a
/// made-up locale: adapters must omit their language hint (or use a provider's
/// real auto-detection API).
public enum RecognitionLanguageMode: Codable, Equatable, Sendable {
    case automatic
    case fixed(localeIdentifier: String)

    private enum CodingKeys: String, CodingKey { case kind, localeIdentifier }
    private enum Kind: String, Codable { case automatic, fixed }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .automatic: self = .automatic
        case .fixed:
            self = .fixed(localeIdentifier: try values.decode(String.self, forKey: .localeIdentifier))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try values.encode(Kind.automatic, forKey: .kind)
        case .fixed(let localeIdentifier):
            try values.encode(Kind.fixed, forKey: .kind)
            try values.encode(localeIdentifier, forKey: .localeIdentifier)
        }
    }
}

/// Persisted settings contain no credentials. No network or device operations here.
public struct CaptionOptions: Codable, Equatable {
    public var service: CaptionService = .azure
    public var region = ""
    public var aliyunHost = ""
    public var selfHostedEndpoint = ""
    public var aliyunModel: AliyunCaptionModel = .qwenAudio31Streaming
    public var languageMode: RecognitionLanguageMode = .fixed(localeIdentifier: "en-GB")
    /// Source-compatible view used by the existing fixed-language subtitle UI.
    /// Assigning `auto` selects real provider auto detection.
    public var language: String {
        get {
            switch languageMode {
            case .automatic: return "auto"
            case .fixed(let localeIdentifier): return localeIdentifier
            }
        }
        set { languageMode = newValue == "auto" ? .automatic : .fixed(localeIdentifier: newValue) }
    }
    public var idleSeconds = 900
    public var maximumSeconds = 7200
    public var recordAudio = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case service, region, aliyunHost, selfHostedEndpoint, aliyunModel, languageMode, language
        case idleSeconds, maximumSeconds, recordAudio
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        service = try values.decodeIfPresent(CaptionService.self, forKey: .service) ?? .azure
        region = try values.decode(String.self, forKey: .region)
        aliyunHost = try values.decodeIfPresent(String.self, forKey: .aliyunHost) ?? ""
        selfHostedEndpoint = try values.decodeIfPresent(String.self, forKey: .selfHostedEndpoint) ?? ""
        // 0.3.3 had only Qwen3 Realtime and therefore no model field. Preserve
        // that explicit user configuration; fresh CaptionOptions default to 3.1.
        aliyunModel = try values.decodeIfPresent(AliyunCaptionModel.self, forKey: .aliyunModel)
            ?? (service == .aliyun ? .qwen3Realtime : .qwenAudio31Streaming)
        if let mode = try values.decodeIfPresent(RecognitionLanguageMode.self, forKey: .languageMode) {
            languageMode = mode
        } else {
            let legacy = try values.decodeIfPresent(String.self, forKey: .language) ?? "en-GB"
            languageMode = legacy == "auto" ? .automatic : .fixed(localeIdentifier: legacy)
        }
        idleSeconds = try values.decode(Int.self, forKey: .idleSeconds)
        maximumSeconds = try values.decode(Int.self, forKey: .maximumSeconds)
        recordAudio = try values.decode(Bool.self, forKey: .recordAudio)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(service, forKey: .service)
        try values.encode(region, forKey: .region)
        try values.encode(aliyunHost, forKey: .aliyunHost)
        try values.encode(selfHostedEndpoint, forKey: .selfHostedEndpoint)
        try values.encode(aliyunModel, forKey: .aliyunModel)
        try values.encode(languageMode, forKey: .languageMode)
        // Keep the legacy scalar during the migration window so older builds can
        // still read fixed configurations. They will reject `auto` rather than
        // silently choosing a language.
        try values.encode(language, forKey: .language)
        try values.encode(idleSeconds, forKey: .idleSeconds)
        try values.encode(maximumSeconds, forKey: .maximumSeconds)
        try values.encode(recordAudio, forKey: .recordAudio)
    }
    public var credentialAccount: String {
        switch service {
        case .azure: return region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .aliyun: return "user-api-key"
        case .selfHostedQwen: return selfHostedEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default: return "default"
        }
    }
    public var credentialService: String {
        service.keychainService + (service == .aliyun ? aliyunHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "")
    }
    public var selectedModel: String {
        service == .aliyun ? aliyunModel.rawValue : service.model
    }

    public static let idleChoices = [0, 60, 300, 900, 1800, 3600]
    public static let durationChoices = [1800, 3600, 7200]
    public static let languages = ["en-GB", "en-US", "zh-CN"]
    public var cloudLanguage: String? {
        if case .fixed(let localeIdentifier) = languageMode { return localeIdentifier }
        return nil
    }
    /// The glasses settings message still requires a concrete source locale.
    /// This does not constrain cloud-side automatic detection.
    public var glassesLanguage: String { cloudLanguage ?? "zh-CN" }
    public var languageName: String { cloudLanguage ?? "自动检测" }
    public func validated() throws -> Self {
        var result = self
        result.region = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if service == .aliyun {
            guard let host = SpeechConfiguration.aliyunHost(aliyunHost) else { throw CaptionFailure.invalidConfiguration }
            result.aliyunHost = host
        }
        if service == .selfHostedQwen {
            guard let endpoint = Self.normalizedSelfHostedEndpoint(selfHostedEndpoint) else {
                throw CaptionFailure.invalidConfiguration
            }
            result.selfHostedEndpoint = endpoint
        }
        // A region identifier, never a URL or arbitrary host receiving a secret.
        if service == .azure {
            guard (3...40).contains(result.region.count), result.region.utf8.allSatisfy({
                (97...122).contains($0) || (48...57).contains($0)
            }) else { throw CaptionFailure.invalidConfiguration }
        }
        switch result.languageMode {
        case .automatic:
            guard service != .deepgram else { throw CaptionFailure.invalidConfiguration }
        case .fixed(let localeIdentifier):
            guard Self.languages.contains(localeIdentifier) else { throw CaptionFailure.invalidConfiguration }
        }
        guard Self.idleChoices.contains(idleSeconds),
              Self.durationChoices.contains(maximumSeconds) else { throw CaptionFailure.invalidConfiguration }
        return result
    }

    public static func normalizedSelfHostedEndpoint(_ value: String) -> String? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard (16...512).contains(raw.utf8.count), var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "wss", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.query == nil,
              components.path.hasSuffix("/realtime") else { return nil }
        components.scheme = "wss"
        components.host = components.host?.lowercased()
        return components.url?.absoluteString
    }
}

public struct CaptionClock {
    public enum Decision: Equatable { case keepListening, audioGap, stopIdle, stopLimit, stopMissingAudio }
    public let startedAt: TimeInterval
    public private(set) var lastAudio: TimeInterval
    public private(set) var lastSpeech: TimeInterval
    private let idle: TimeInterval
    private let maximum: TimeInterval
    public init(options: CaptionOptions, now: TimeInterval) {
        startedAt = now; lastAudio = now; lastSpeech = now
        idle = TimeInterval(options.idleSeconds); maximum = TimeInterval(options.maximumSeconds)
    }
    public mutating func audio(now: TimeInterval) { lastAudio = max(lastAudio, now) }
    public mutating func speech(now: TimeInterval) { lastSpeech = max(lastSpeech, now) }
    public func decision(now: TimeInterval) -> Decision {
        if now - startedAt >= maximum { return .stopLimit }
        // Missing packets must never be classified as acoustic silence.
        if now - lastAudio >= 15 { return .stopMissingAudio }
        if now - lastAudio >= 5 { return .audioGap }
        if idle > 0 && now - lastSpeech >= idle { return .stopIdle }
        return .keepListening
    }
}

/// 120 ms of speech in a 200 ms window. Ambient noise is not simply "sound".
public struct CaptionVoiceActivity {
    private var frames: [Bool] = []
    public init() {}
    public mutating func accept(_ speech: Bool) -> Bool {
        frames.append(speech)
        if frames.count > 20 { frames.removeFirst() }
        return speech && frames.filter { $0 }.count >= 12
    }
}

/// Bounded retries for a cloud connection only; never restarts a glasses microphone.
public struct CaptionRetryBudget {
    public private(set) var attempts = 0
    public init() {}
    public mutating func nextDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4]
        guard attempts < delays.count else { return nil }
        defer { attempts += 1 }
        return delays[attempts]
    }
    // Reset only after a useful recognition result, not after a socket handshake.
    public mutating func recognized() { attempts = 0 }
}

public enum CaptionText {
    /// Preserve the newest characters without cutting a UTF-8 sequence or grapheme.
    /// This is a bounded text window, not a claim to control firmware line layout.
    public static func lensWindow(_ text: String, maximumBytes: Int = 480) -> String {
        var characters: [Character] = [], count = 0
        for character in text.reversed() {
            let bytes = String(character).utf8.count
            guard count + bytes <= maximumBytes else { break }
            characters.append(character); count += bytes
        }
        return String(characters.reversed())
    }
}
