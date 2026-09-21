import Foundation
import Combine
import RayNeoCaptions

protocol SpeechCredentialStorage {
    func asrKey(_ configuration: SpeechConfiguration) -> String?
    func saveASR(_ key: String, configuration: SpeechConfiguration) throws
    func removeASR(_ configuration: SpeechConfiguration) throws
    func modelKey() -> String?
    func saveModel(_ key: String) throws
    func removeModel() throws
}

struct SpeechKeychainStorage: SpeechCredentialStorage {
    func asrKey(_ configuration: SpeechConfiguration) -> String? { CaptionCredentials.read(options: configuration.applying()) }
    func saveASR(_ key: String, configuration: SpeechConfiguration) throws { try CaptionCredentials.save(key, options: configuration.applying()) }
    func removeASR(_ configuration: SpeechConfiguration) throws { try CaptionCredentials.remove(options: configuration.applying()) }
    func modelKey() -> String? { CloudVoiceKeys.get(CloudVoiceKeys.llmService) }
    func saveModel(_ key: String) throws {
        guard CloudVoiceKeys.save(key, service: CloudVoiceKeys.llmService) else { throw CaptionFailure.invalidConfiguration }
    }
    func removeModel() throws { try CloudVoiceKeys.remove(CloudVoiceKeys.llmService) }
}

@MainActor final class SpeechSettingsStore: ObservableObject {
    static let settingsKey = "companion.speech.configuration.v2"
    @Published private(set) var configuration: SpeechConfiguration
    @Published private(set) var hasASRKey = false
    @Published private(set) var hasModelKey = false
    @Published var error: String?
    let allowsCredentialChanges: Bool
    private let defaults: UserDefaults
    private let credentials: SpeechCredentialStorage
    private let providerFactory: (SpeechService) -> CaptionASRProvider?
    var isBusy: (() -> Bool)?

    init(defaults: UserDefaults = .standard, credentials: SpeechCredentialStorage = SpeechKeychainStorage(),
         allowsCredentialChanges: Bool? = nil,
         providerFactory: ((SpeechService) -> CaptionASRProvider?)? = nil) {
        self.defaults = defaults; self.credentials = credentials; self.providerFactory = providerFactory ?? { CaptionASRFactory.make($0) }
        #if COMPANION_DEVICE
        self.allowsCredentialChanges = allowsCredentialChanges ?? true
        #else
        self.allowsCredentialChanges = allowsCredentialChanges ?? false
        #endif
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(SpeechConfiguration.self, from: data) {
            configuration = saved
        } else {
            let host = CloudASRHostSettings.current(defaults: defaults)
            if let data = defaults.data(forKey: "companion.azureCaptions.options.v1"),
               let saved = try? JSONDecoder().decode(CaptionOptions.self, from: data) {
                configuration = SpeechConfiguration(options: saved)
                configuration.aliyunHost = host
            } else {
                configuration = SpeechConfiguration()
                if !host.isEmpty { configuration.service = .aliyun; configuration.aliyunHost = host; configuration.language = "zh-CN" }
            }
            // Only a configuration migration: never enables standby, recording, or network.
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.settingsKey) }
        }
        refresh()
    }
    var captionRequirements: [String] { configuration.missingRequirements(asrKey: hasASRKey, modelKey: hasModelKey, conversation: false) }
    var conversationRequirements: [String] { configuration.missingRequirements(asrKey: hasASRKey, modelKey: hasModelKey, conversation: true) }
    func refresh() { hasASRKey = credentials.asrKey(configuration) != nil; hasModelKey = credentials.modelKey() != nil }
    func hasKey(for value: SpeechConfiguration) -> Bool { credentials.asrKey(value) != nil }
    func key(for value: SpeechConfiguration) -> String? { credentials.asrKey(value) }
    @discardableResult func save(_ draft: SpeechConfiguration, asrKey: String = "", modelKey: String = "") -> Bool {
        guard allowsCredentialChanges, isBusy?() != true else { error = "请在真机中停止字幕和语音待命后修改服务。"; return false }
        do {
            let value = try draft.validated()
            // Validate both inputs before changing either credential. Blank means preserve.
            guard (asrKey.isEmpty || CaptionStreamingAPI.validKey(asrKey)),
                  (modelKey.isEmpty || (CaptionStreamingAPI.validKey(modelKey) && modelKey.hasPrefix("sk-"))) else {
                throw CaptionFailure.invalidConfiguration
            }
            if !asrKey.isEmpty { try credentials.saveASR(asrKey, configuration: value) }
            if !modelKey.isEmpty { try credentials.saveModel(modelKey) }
            defaults.set(try JSONEncoder().encode(value), forKey: Self.settingsKey)
            if let host = SpeechConfiguration.aliyunHost(value.aliyunHost) { CloudASRHostSettings.save(host, defaults: defaults) }
            configuration = value; error = nil; refresh(); return true
        } catch { self.error = "未完成保存，请检查当前服务的配置、密钥格式和钥匙串状态。"; refresh(); return false }
    }
    func removeASR(_ value: SpeechConfiguration) {
        guard allowsCredentialChanges, isBusy?() != true else { return }
        do { try credentials.removeASR(value); error = nil; refresh() }
        catch { self.error = "无法删除当前转写密钥。" }
    }
    func removeModel() {
        guard allowsCredentialChanges, isBusy?() != true else { return }
        do { try credentials.removeModel(); error = nil; refresh() }
        catch { self.error = "无法删除 DeepSeek 密钥。" }
    }
    func makeConversationRecognition() -> VoiceRecognitionPort? {
        let snapshot = configuration
        guard let options = try? snapshot.applying().validated(), let key = credentials.asrKey(snapshot),
              let provider = providerFactory(snapshot.service) else { return nil }
        return VoiceRecognitionPort(start: { text, endpoint, failure in
            provider.onText = text; provider.onEndpoint = endpoint
            provider.onFailure = { failure("\(snapshot.service.name)：\($0.message)") }
            provider.start(options: options, key: key)
        }, append: { provider.append($0) }, stop: { provider.stop() })
    }
}
