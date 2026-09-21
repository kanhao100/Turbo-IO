import Foundation

public typealias SpeechService = CaptionService

/// One ASR configuration shared by captions and AI conversation. Session/recording
/// consent and the language model credential are deliberately not ASR settings.
public struct SpeechConfiguration: Codable, Equatable {
    public var service: SpeechService = .azure
    public var region = ""
    public var aliyunHost = ""
    public var language = "en-GB"
    public init() {}
    public init(options: CaptionOptions) {
        service = options.service; region = options.region; aliyunHost = options.aliyunHost; language = options.language
    }
    public func applying(to policy: CaptionOptions = CaptionOptions()) -> CaptionOptions {
        var value = policy
        value.service = service; value.region = region; value.aliyunHost = aliyunHost; value.language = language
        return value
    }
    public func validated() throws -> Self { Self(options: try applying().validated()) }
    public static func aliyunHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host.utf8.count <= 253, host.hasSuffix(".aliyuncs.com"),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45 }
              }) else { return nil }
        return host
    }
    public func missingRequirements(asrKey: Bool, modelKey: Bool, conversation: Bool) -> [String] {
        var missing: [String] = []
        if (try? validated()) == nil {
            missing.append(service == .azure ? "Azure Region 或识别语言" : service == .aliyun ? "阿里云 Host 或识别语言" : "识别语言")
        }
        if !asrKey { missing.append("\(service.name) API Key") }
        if conversation && !modelKey { missing.append("DeepSeek API Key（用于生成回答）") }
        return missing
    }
}
