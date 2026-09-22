import Foundation

public typealias SpeechService = CaptionService

/// Alibaba Cloud workspace endpoints supported by both subtitle protocols.
/// API keys and workspaces are region-scoped, so callers must keep the complete
/// workspace host instead of selecting a region independently.
public enum AliyunRealtimeRegion: String, Codable, CaseIterable {
    case chinaBeijing = "cn-beijing"
    case singapore = "ap-southeast-1"

    public var name: String {
        switch self {
        case .chinaBeijing: return "中国北京"
        case .singapore: return "新加坡"
        }
    }

    public static func region(for host: String) -> Self? {
        guard let normalized = normalizedDNSHost(host) else { return nil }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 5, labels[0] != "trial", labels[2] == "maas",
              labels[3] == "aliyuncs", labels[4] == "com" else { return nil }
        return Self(rawValue: String(labels[1]))
    }

    public static func normalize(host: String) -> String? {
        guard region(for: host) != nil else { return nil }
        return host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedDNSHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host.utf8.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.unicodeScalars.allSatisfy {
                      (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45
                  }
              }) else { return nil }
        return host
    }
}

/// One ASR configuration shared by captions and AI conversation. Session/recording
/// consent and the language model credential are deliberately not ASR settings.
public struct SpeechConfiguration: Codable, Equatable {
    public var service: SpeechService = .azure
    public var region = ""
    public var aliyunHost = ""
    public var selfHostedEndpoint = ""
    public var language = "en-GB"
    public init() {}
    public init(options: CaptionOptions) {
        service = options.service; region = options.region; aliyunHost = options.aliyunHost
        selfHostedEndpoint = options.selfHostedEndpoint; language = options.language
    }
    public func applying(to policy: CaptionOptions = CaptionOptions()) -> CaptionOptions {
        var value = policy
        value.service = service; value.region = region; value.aliyunHost = aliyunHost
        value.selfHostedEndpoint = selfHostedEndpoint; value.language = language
        return value
    }
    private enum CodingKeys: String, CodingKey { case service, region, aliyunHost, selfHostedEndpoint, language }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        service = try values.decodeIfPresent(SpeechService.self, forKey: .service) ?? .azure
        region = try values.decodeIfPresent(String.self, forKey: .region) ?? ""
        aliyunHost = try values.decodeIfPresent(String.self, forKey: .aliyunHost) ?? ""
        selfHostedEndpoint = try values.decodeIfPresent(String.self, forKey: .selfHostedEndpoint) ?? ""
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en-GB"
    }
    public func validated() throws -> Self { Self(options: try applying().validated()) }
    public static func aliyunHost(_ value: String) -> String? {
        AliyunRealtimeRegion.normalize(host: value)
    }
    public func missingRequirements(asrKey: Bool, modelKey: Bool, conversation: Bool) -> [String] {
        var missing: [String] = []
        if (try? validated()) == nil {
            switch service {
            case .azure: missing.append("Azure Region 或识别语言")
            case .aliyun: missing.append("阿里云 Workspace Host 或识别语言")
            case .selfHostedQwen: missing.append("自建 Qwen WSS Realtime 地址或识别语言")
            case .deepgram, .elevenLabs: missing.append("识别语言")
            }
        }
        if !asrKey { missing.append("\(service.name) API Key") }
        if conversation && !modelKey { missing.append("DeepSeek API Key（用于生成回答）") }
        return missing
    }
}
