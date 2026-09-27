import Foundation
import Combine
import RayNeoCaptions
import RayNeoProtocol

enum SubtitleInputSource: String, CaseIterable, Codable {
    case glasses, iPhoneMicrophone, systemMicrophone

    var name: String {
        switch self {
        case .glasses: return "眼镜音频流"
        case .iPhoneMicrophone: return "iPhone 内置麦克风"
        case .systemMicrophone: return "系统麦克风"
        }
    }
}

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
    static let pickupDirectionKey = "companion.realtimeSubtitles.pickupDirection.v1"
    static let inputSourceKey = "companion.realtimeSubtitles.inputSource.v1"
    static let systemInputUIDKey = "companion.realtimeSubtitles.systemInputUID.v1"
    static let translationEnabledKey = "companion.realtimeSubtitles.translationEnabled.v1"
    static let showOnGlassesKey = "companion.realtimeSubtitles.showOnGlasses.v1"
    @Published private(set) var options: CaptionOptions
    @Published private(set) var pickupDirection: SubtitleTranslateWire.PickupDirection
    @Published private(set) var inputSource: SubtitleInputSource
    @Published private(set) var systemInputUID: String?
    @Published private(set) var translationEnabled: Bool
    @Published private(set) var showOnGlasses: Bool
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
        pickupDirection = SubtitleTranslateWire.PickupDirection(
            rawValue: defaults.string(forKey: Self.pickupDirectionKey) ?? "") ?? .around
        inputSource = SubtitleInputSource(rawValue: defaults.string(forKey: Self.inputSourceKey) ?? "") ?? .glasses
        systemInputUID = defaults.string(forKey: Self.systemInputUIDKey)
        translationEnabled = defaults.bool(forKey: Self.translationEnabledKey)
        showOnGlasses = defaults.object(forKey: Self.showOnGlassesKey) as? Bool ?? true
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
    func saveInputSource(_ value: SubtitleInputSource, systemInputUID: String? = nil) {
        guard allowsChanges, isBusy?() != true else { error = "请先结束当前会话，再切换音频来源。"; return }
        inputSource = value
        defaults.set(value.rawValue, forKey: Self.inputSourceKey)
        if value == .systemMicrophone {
            self.systemInputUID = systemInputUID
            if let systemInputUID { defaults.set(systemInputUID, forKey: Self.systemInputUIDKey) }
            else { defaults.removeObject(forKey: Self.systemInputUIDKey) }
        }
        error = nil
    }
    func saveTranslationEnabled(_ value: Bool) {
        guard allowsChanges, isBusy?() != true else { error = "请先结束当前会话，再修改本地翻译。"; return }
        translationEnabled = value; defaults.set(value, forKey: Self.translationEnabledKey); error = nil
    }
    func saveShowOnGlasses(_ value: Bool) {
        guard allowsChanges, isBusy?() != true else { error = "请先结束当前会话，再修改字幕显示位置。"; return }
        showOnGlasses = value; defaults.set(value, forKey: Self.showOnGlassesKey); error = nil
    }
    @discardableResult func savePickupDirection(_ direction: SubtitleTranslateWire.PickupDirection) -> Bool {
        guard allowsChanges else { error = "当前设备不能修改字幕收音方向。"; return false }
        defaults.set(direction.rawValue, forKey: Self.pickupDirectionKey)
        pickupDirection = direction; error = nil
        return true
    }
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
        guard let value = try? requested.validated(), let provider = factory(value.service) else { return nil }
        let key: String
        if value.service == .appleLocal { key = "" }
        else {
            guard let saved = credentials.key(for: value), !saved.isEmpty else { return nil }
            key = saved
        }
        return (value, key, provider)
    }
}
