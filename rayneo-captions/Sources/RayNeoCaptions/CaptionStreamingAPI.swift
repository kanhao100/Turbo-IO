import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CaptionConnectionFailure: Error, Equatable {
    case configuration, authentication, quota, rejected, connection, backpressure, invalidResponse
    public var canRetry: Bool { self == .connection || self == .backpressure }
    public var message: String {
        switch self {
        case .configuration: return "请检查服务、语言和密钥格式"
        case .authentication: return "密钥无效或没有转写权限，请检查此服务的 API Key"
        case .quota: return "服务额度或速率受限，请检查账户额度与并发限制"
        case .rejected: return "服务拒绝了会话，请检查账户权限、条款及模型可用性"
        case .connection: return "连接中断或服务暂时不可用"
        case .backpressure: return "上传速度跟不上实时音频"
        case .invalidResponse: return "服务返回了无法处理的转写数据"
        }
    }
    public static func httpStatus(_ status: Int?) -> Self {
        guard let status else { return .connection }
        switch status {
        case 401, 403: return .authentication
        case 402, 429: return .quota
        case 400, 404, 422: return .configuration
        case 300..<400: return .rejected
        default: return .connection
        }
    }
}

public enum CaptionStreamEvent: Equatable {
    case ready, text(String, final: Bool, utteranceEnd: Bool), failure(CaptionConnectionFailure), ignored
}

/// Pure wire format adapter. Only the app's explicitly armed device session opens sockets.
public enum CaptionStreamingAPI {
    public static func validKey(_ key: String) -> Bool {
        (16...512).contains(key.utf8.count) && key.utf8.allSatisfy { (33...126).contains($0) }
    }
    public static func request(options: CaptionOptions, key: String) throws -> URLRequest {
        let options = try options.validated()
        guard validKey(key), options.service != .azure else { throw CaptionConnectionFailure.configuration }
        var url: URLComponents
        let headers: [String: String]
        switch options.service {
        case .deepgram:
            url = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
            url.queryItems = ["model": "nova-3", "language": options.language,
                "encoding": "linear16", "sample_rate": "16000", "channels": "1",
                "interim_results": "true", "punctuate": "true", "smart_format": "true",
                "endpointing": "300"].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            headers = ["Authorization": "Token \(key)"]
        case .elevenLabs:
            url = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
            url.queryItems = ["model_id": "scribe_v2_realtime", "audio_format": "pcm_16000",
                "language_code": options.language == "zh-CN" ? "zh" : "en",
                "commit_strategy": "vad", "include_timestamps": "false",
                "include_language_detection": "false"].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            headers = ["xi-api-key": key]
        case .azure, .aliyun: throw CaptionConnectionFailure.configuration
        }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        request.allHTTPHeaderFields = headers
        return request
    }
    public static func elevenLabsAudio(_ pcm: Data) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(), "commit": false] as [String: Any])
        return String(decoding: data, as: UTF8.self)
    }
    public static func event(_ data: Data, service: CaptionService) throws -> CaptionStreamEvent {
        guard data.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptionConnectionFailure.invalidResponse
        }
        switch service {
        case .deepgram:
            guard let type = object["type"] as? String else { throw CaptionConnectionFailure.invalidResponse }
            if type == "Error" { return .failure(.rejected) }
            guard type == "Results" else { return .ignored }
            guard let channel = object["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let text = alternatives.first?["transcript"] as? String,
                  let final = object["is_final"] as? Bool else { throw CaptionConnectionFailure.invalidResponse }
            // is_final seals a segment even before speech_final ends the utterance.
            return try transcript(text, final: final, utteranceEnd: object["speech_final"] as? Bool == true)
        case .elevenLabs:
            guard let type = object["message_type"] as? String else { throw CaptionConnectionFailure.invalidResponse }
            switch type {
            case "session_started": return .ready
            case "partial_transcript", "committed_transcript":
                guard let text = object["text"] as? String else { throw CaptionConnectionFailure.invalidResponse }
                return try transcript(text, final: type == "committed_transcript", utteranceEnd: type == "committed_transcript")
            // This is an additional delayed copy of the same commit, never a second subtitle.
            case "committed_transcript_with_timestamps", "committed_transcript_entities", "warning": return .ignored
            case "auth_error": return .failure(.authentication)
            case "quota_exceeded", "rate_limited", "throttled", "commit_throttled": return .failure(.quota)
            case "queue_overflow", "resource_exhausted", "transcriber_error", "session_time_limit_exceeded",
                 "insufficient_audio_activity": return .failure(.connection)
            case "error", "unaccepted_terms", "input_error", "invalid_request", "chunk_size_exceeded": return .failure(.rejected)
            default: return object["error"] == nil ? .ignored : .failure(.rejected)
            }
        case .azure, .aliyun: throw CaptionConnectionFailure.configuration
        }
    }
    private static func transcript(_ text: String, final: Bool, utteranceEnd: Bool) throws -> CaptionStreamEvent {
        guard text.utf8.count <= 32_768 else { throw CaptionConnectionFailure.invalidResponse }
        return .text(text, final: final, utteranceEnd: utteranceEnd)
    }
}

/// 100 ms PCM16/16 kHz mono chunks; at most 2 s pending plus one in-flight chunk.
/// Overflow causes a visible reconnect gap, never an unbounded delayed replay.
public struct CaptionAudioBuffer {
    private var bytes = Data()
    public var count: Int { bytes.count }
    public init() {}
    public mutating func append(_ pcm: Data) throws {
        guard !pcm.isEmpty, pcm.count <= 3_840, pcm.count % 2 == 0 else { throw CaptionConnectionFailure.configuration }
        guard bytes.count + pcm.count <= 64_000 else { throw CaptionConnectionFailure.backpressure }
        bytes.append(pcm)
    }
    public mutating func next() -> Data? {
        guard bytes.count >= 3_200 else { return nil }
        let chunk = Data(bytes.prefix(3_200)); bytes.removeFirst(3_200)
        return chunk
    }
}
