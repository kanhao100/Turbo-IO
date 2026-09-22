import Foundation
import Combine
import RayNeoCaptions

protocol SubtitleCredentialStorage {
    func key(for options: CaptionOptions) -> String?
    func save(_ key: String, for options: CaptionOptions) throws
    func remove(for options: CaptionOptions) throws
}

struct SubtitleKeychainStorage: SubtitleCredentialStorage {
    func key(for options: CaptionOptions) -> String? { CaptionCredentials.read(options: options) }
    func save(_ key: String, for options: CaptionOptions) throws { try CaptionCredentials.save(key, options: options) }
    func remove(for options: CaptionOptions) throws { try CaptionCredentials.remove(options: options) }
}

/// ASR settings for native subtitles. Saving never opens a device or cloud session.
@MainActor final class SubtitleSettingsStore: ObservableObject {
    static let preferencesKey = "companion.realtimeSubtitles.options.v1"
    @Published private(set) var options: CaptionOptions
    @Published private(set) var hasKey = false
    @Published var error: String?
    var isBusy: (() -> Bool)?
    private let defaults: UserDefaults
    private let credentials: SubtitleCredentialStorage
    private let factory: (CaptionService) -> CaptionASRProvider?
    let allowsChanges: Bool

    init(defaults: UserDefaults = .standard, credentials: SubtitleCredentialStorage = SubtitleKeychainStorage(),
         allowsChanges: Bool? = nil, factory: ((CaptionService) -> CaptionASRProvider?)? = nil) {
        self.defaults = defaults; self.credentials = credentials
        self.factory = factory ?? { CaptionASRFactory.make($0) }
        #if COMPANION_DEVICE
        self.allowsChanges = allowsChanges ?? true
        #else
        self.allowsChanges = allowsChanges ?? false
        #endif
        if let saved = defaults.data(forKey: Self.preferencesKey),
           let decoded = try? JSONDecoder().decode(CaptionOptions.self, from: saved) {
            options = decoded
        } else {
            var initial = CaptionOptions()
            initial.language = "zh-CN"; initial.maximumSeconds = 3600
            initial.idleSeconds = 0; initial.recordAudio = true
            if let data = defaults.data(forKey: "companion.speech.configuration.v2"),
               let shared = try? JSONDecoder().decode(SpeechConfiguration.self, from: data) {
                initial = shared.applying(to: initial)
            } else if let data = defaults.data(forKey: "companion.azureCaptions.options.v1"),
                      let previous = try? JSONDecoder().decode(CaptionOptions.self, from: data) {
                initial = SpeechConfiguration(options: previous).applying(to: initial)
            } else {
                let host = CloudASRHostSettings.current(defaults: defaults)
                if !host.isEmpty { initial.service = .aliyun; initial.aliyunHost = host }
            }
            options = initial
        }
        refresh()
    }
    var requirements: [String] {
        SpeechConfiguration(options: options).missingRequirements(asrKey: hasKey, modelKey: false, conversation: false)
    }
    func refresh() { hasKey = credentials.key(for: options).map { !$0.isEmpty } ?? false }
    func hasKey(for value: CaptionOptions) -> Bool { credentials.key(for: value).map { !$0.isEmpty } ?? false }
    @discardableResult func save(_ draft: CaptionOptions, key: String = "", allowActiveAlwaysOn: Bool = false) -> Bool {
        guard allowsChanges, allowActiveAlwaysOn || isBusy?() != true else { error = "请先结束字幕或语音会话，再修改设置。"; return false }
        do {
            let value = try draft.validated()
            if !key.isEmpty { try credentials.save(key, for: value) }
            defaults.set(try JSONEncoder().encode(value), forKey: Self.preferencesKey)
            options = value; error = nil; refresh(); return true
        } catch { self.error = "未完成保存，请检查当前服务的配置、密钥格式和钥匙串状态。"; return false }
    }
    func forgetKey(for value: CaptionOptions) {
        guard allowsChanges, isBusy?() != true else { return }
        do { try credentials.remove(for: value); error = nil; refresh() }
        catch { self.error = "无法移除此服务的密钥。" }
    }
    func recognizer() -> (options: CaptionOptions, key: String, provider: CaptionASRProvider)? {
        recognizer(for: options)
    }
    func recognizer(for requested: CaptionOptions) -> (options: CaptionOptions, key: String, provider: CaptionASRProvider)? {
        refresh()
        guard let value = try? requested.validated(), let key = credentials.key(for: value), !key.isEmpty,
              let provider = factory(value.service) else { return nil }
        return (value, key, provider)
    }
}
