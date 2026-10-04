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

enum SubtitleDisplayMode: String, CaseIterable, Codable {
    case chineseOnly, englishOnly, bilingual

    var name: String {
        switch self {
        case .chineseOnly: return "只看中文"
        case .englishOnly: return "只看英文"
        case .bilingual: return "中英混合"
        }
    }
}

enum SubtitleBilingualOrder: String, CaseIterable, Codable {
    case sourceFirst, translationFirst

    var name: String {
        switch self {
        case .sourceFirst: return "原文在上"
        case .translationFirst: return "译文在上"
        }
    }
}

enum SubtitleDisplayLayout: String, CaseIterable, Codable {
    case rolling, sentence

    var name: String {
        switch self {
        case .rolling: return "滚动分区"
        case .sentence: return "按段替换"
        }
    }
}

enum SubtitleTranslationQuality: String, CaseIterable, Codable {
    case lowLatency, highFidelity

    var name: String {
        switch self {
        case .lowLatency: return "低延迟"
        case .highFidelity: return "高保真"
        }
    }

    var detail: String {
        switch self {
        case .lowLatency: return "优先快速返回译文，适合实时对话。"
        case .highFidelity: return "iOS 26.4 及支持 Apple Intelligence 的设备会优先使用高保真翻译，可能更慢；其他环境回退到低延迟。"
        }
    }
}

enum SubtitleDisplayRetention: String, CaseIterable, Codable {
    case untilNextSentence, seconds3, seconds5, seconds10, custom

    var name: String {
        switch self {
        case .untilNextSentence: return "直到下一句"
        case .seconds3: return "3 秒"
        case .seconds5: return "5 秒"
        case .seconds10: return "10 秒"
        case .custom: return "自定义"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .untilNextSentence: return nil
        case .seconds3: return 3
        case .seconds5: return 5
        case .seconds10: return 10
        case .custom: return nil
        }
    }
}

private struct SubtitleDisplayPreferences: Codable {
    var mode: SubtitleDisplayMode
    var order: SubtitleBilingualOrder
    var retention: SubtitleDisplayRetention
    var showLiveSourceDuringTranslation: Bool
    var customRetentionSeconds: Double
    var partialUpdateIntervalSeconds: Double
    var nextSentenceTakeoverDelaySeconds: Double
    var minimumSourceVisibleSeconds: Double
    var translationRevealDelaySeconds: Double
    var translationMinimumVisibleSeconds: Double
    var lensUpdateIntervalSeconds: Double
    var displayLayout: SubtitleDisplayLayout
    var rollingConfiguration: CaptionRollingConfiguration

    init(mode: SubtitleDisplayMode, order: SubtitleBilingualOrder,
         retention: SubtitleDisplayRetention, showLiveSourceDuringTranslation: Bool = true,
         customRetentionSeconds: Double = 5,
         partialUpdateIntervalSeconds: Double = 0,
         nextSentenceTakeoverDelaySeconds: Double = 0,
         minimumSourceVisibleSeconds: Double = 0,
         translationRevealDelaySeconds: Double = 0,
         translationMinimumVisibleSeconds: Double = 1.5,
         lensUpdateIntervalSeconds: Double = 0.5,
         displayLayout: SubtitleDisplayLayout = .rolling,
         rollingConfiguration: CaptionRollingConfiguration = CaptionRollingConfiguration()) {
        self.mode = mode
        self.order = order
        self.retention = retention
        self.showLiveSourceDuringTranslation = showLiveSourceDuringTranslation
        self.customRetentionSeconds = customRetentionSeconds
        self.partialUpdateIntervalSeconds = partialUpdateIntervalSeconds
        self.nextSentenceTakeoverDelaySeconds = nextSentenceTakeoverDelaySeconds
        self.minimumSourceVisibleSeconds = minimumSourceVisibleSeconds
        self.translationRevealDelaySeconds = translationRevealDelaySeconds
        self.translationMinimumVisibleSeconds = translationMinimumVisibleSeconds
        self.lensUpdateIntervalSeconds = lensUpdateIntervalSeconds
        self.displayLayout = displayLayout
        self.rollingConfiguration = rollingConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case mode, order, retention, showLiveSourceDuringTranslation, customRetentionSeconds
        case partialUpdateIntervalSeconds, nextSentenceTakeoverDelaySeconds
        case minimumSourceVisibleSeconds, translationRevealDelaySeconds, lensUpdateIntervalSeconds
        case translationMinimumVisibleSeconds
        case displayLayout, rollingConfiguration
    }
    private enum RollingMigrationKeys: String, CodingKey { case englishWidthPercent }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(SubtitleDisplayMode.self, forKey: .mode)
        order = try container.decode(SubtitleBilingualOrder.self, forKey: .order)
        retention = try container.decode(SubtitleDisplayRetention.self, forKey: .retention)
        showLiveSourceDuringTranslation = try container.decodeIfPresent(
            Bool.self, forKey: .showLiveSourceDuringTranslation) ?? true
        customRetentionSeconds = try container.decodeIfPresent(
            Double.self, forKey: .customRetentionSeconds) ?? 5
        partialUpdateIntervalSeconds = try container.decodeIfPresent(
            Double.self, forKey: .partialUpdateIntervalSeconds) ?? 0
        nextSentenceTakeoverDelaySeconds = try container.decodeIfPresent(
            Double.self, forKey: .nextSentenceTakeoverDelaySeconds) ?? 0
        minimumSourceVisibleSeconds = try container.decodeIfPresent(
            Double.self, forKey: .minimumSourceVisibleSeconds) ?? 0
        translationRevealDelaySeconds = try container.decodeIfPresent(
            Double.self, forKey: .translationRevealDelaySeconds) ?? 0
        translationMinimumVisibleSeconds = try container.decodeIfPresent(
            Double.self, forKey: .translationMinimumVisibleSeconds) ?? 1.5
        lensUpdateIntervalSeconds = try container.decodeIfPresent(
            Double.self, forKey: .lensUpdateIntervalSeconds) ?? 0.5
        displayLayout = try container.decodeIfPresent(
            SubtitleDisplayLayout.self, forKey: .displayLayout) ?? .rolling
        rollingConfiguration = try container.decodeIfPresent(
            CaptionRollingConfiguration.self, forKey: .rollingConfiguration) ?? CaptionRollingConfiguration()
        if container.contains(.rollingConfiguration) {
            let saved = try container.nestedContainer(keyedBy: RollingMigrationKeys.self, forKey: .rollingConfiguration)
            if !saved.contains(.englishWidthPercent), rollingConfiguration.sourceLines == 3,
               rollingConfiguration.columns == 28, rollingConfiguration.scrollUnit == .line {
                rollingConfiguration.columns = 40
            }
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
    static let translationQualityKey = "companion.realtimeSubtitles.translationQuality.v1"
    static let showOnGlassesKey = "companion.realtimeSubtitles.showOnGlasses.v1"
    static let displayPreferencesKey = "companion.realtimeSubtitles.displayPreferences.v1"
    @Published private(set) var options: CaptionOptions
    @Published private(set) var pickupDirection: SubtitleTranslateWire.PickupDirection
    @Published private(set) var inputSource: SubtitleInputSource
    @Published private(set) var systemInputUID: String?
    @Published private(set) var translationEnabled: Bool
    @Published private(set) var translationQuality: SubtitleTranslationQuality
    @Published private(set) var showOnGlasses: Bool
    @Published private(set) var displayMode: SubtitleDisplayMode
    @Published private(set) var bilingualOrder: SubtitleBilingualOrder
    @Published private(set) var displayRetention: SubtitleDisplayRetention
    @Published private(set) var showLiveSourceDuringTranslation: Bool
    @Published private(set) var customRetentionSeconds: Double
    @Published private(set) var partialUpdateIntervalSeconds: Double
    @Published private(set) var nextSentenceTakeoverDelaySeconds: Double
    @Published private(set) var minimumSourceVisibleSeconds: Double
    @Published private(set) var translationRevealDelaySeconds: Double
    @Published private(set) var translationMinimumVisibleSeconds: Double
    @Published private(set) var lensUpdateIntervalSeconds: Double
    @Published private(set) var displayLayout: SubtitleDisplayLayout
    @Published private(set) var rollingConfiguration: CaptionRollingConfiguration
    var effectiveRetentionSeconds: TimeInterval? {
        displayRetention == .custom ? customRetentionSeconds : displayRetention.seconds
    }
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
        translationQuality = SubtitleTranslationQuality(
            rawValue: defaults.string(forKey: Self.translationQualityKey) ?? "") ?? .lowLatency
        showOnGlasses = defaults.object(forKey: Self.showOnGlassesKey) as? Bool ?? true
        let display = defaults.data(forKey: Self.displayPreferencesKey)
            .flatMap { try? JSONDecoder().decode(SubtitleDisplayPreferences.self, from: $0) }
            ?? SubtitleDisplayPreferences(mode: .bilingual, order: .sourceFirst, retention: .untilNextSentence)
        displayMode = display.mode
        bilingualOrder = display.order
        displayRetention = display.retention
        showLiveSourceDuringTranslation = display.showLiveSourceDuringTranslation
        customRetentionSeconds = Self.clampSeconds(display.customRetentionSeconds, range: 0...30, fallback: 5)
        partialUpdateIntervalSeconds = Self.clampSeconds(display.partialUpdateIntervalSeconds, range: 0...1, fallback: 0)
        nextSentenceTakeoverDelaySeconds = Self.clampSeconds(display.nextSentenceTakeoverDelaySeconds, range: 0...1, fallback: 0)
        minimumSourceVisibleSeconds = Self.clampSeconds(display.minimumSourceVisibleSeconds, range: 0...3, fallback: 0)
        translationRevealDelaySeconds = Self.clampSeconds(display.translationRevealDelaySeconds, range: 0...3, fallback: 0)
        translationMinimumVisibleSeconds = Self.clampSeconds(display.translationMinimumVisibleSeconds, range: 0...5, fallback: 1.5)
        lensUpdateIntervalSeconds = Self.clampSeconds(display.lensUpdateIntervalSeconds, range: 0.5...2, fallback: 0.5)
        displayLayout = display.displayLayout
        rollingConfiguration = display.rollingConfiguration.normalized
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
    func saveTranslationQuality(_ value: SubtitleTranslationQuality) {
        guard allowsChanges, isBusy?() != true else { error = "请先结束当前会话，再修改本地翻译策略。"; return }
        translationQuality = value
        defaults.set(value.rawValue, forKey: Self.translationQualityKey)
        error = nil
    }
    func saveShowOnGlasses(_ value: Bool) {
        guard allowsChanges, isBusy?() != true else { error = "请先结束当前会话，再修改字幕显示位置。"; return }
        showOnGlasses = value; defaults.set(value, forKey: Self.showOnGlassesKey); error = nil
    }
    @discardableResult func saveDisplayPreferences(
        mode: SubtitleDisplayMode,
        order: SubtitleBilingualOrder,
        retention: SubtitleDisplayRetention,
        showLiveSourceDuringTranslation: Bool? = nil,
        customRetentionSeconds: Double? = nil,
        partialUpdateIntervalSeconds: Double? = nil,
        nextSentenceTakeoverDelaySeconds: Double? = nil,
        minimumSourceVisibleSeconds: Double? = nil,
        translationRevealDelaySeconds: Double? = nil,
        translationMinimumVisibleSeconds: Double? = nil,
        lensUpdateIntervalSeconds: Double? = nil,
        displayLayout: SubtitleDisplayLayout? = nil,
        rollingConfiguration: CaptionRollingConfiguration? = nil
    ) -> Bool {
        guard allowsChanges else { error = "当前设备不能修改字幕显示设置。"; return false }
        do {
            let liveSource = showLiveSourceDuringTranslation ?? self.showLiveSourceDuringTranslation
            let customSeconds = customRetentionSeconds ?? self.customRetentionSeconds
            let partialSeconds = partialUpdateIntervalSeconds ?? self.partialUpdateIntervalSeconds
            let takeoverSeconds = nextSentenceTakeoverDelaySeconds ?? self.nextSentenceTakeoverDelaySeconds
            let sourceSeconds = minimumSourceVisibleSeconds ?? self.minimumSourceVisibleSeconds
            let revealSeconds = translationRevealDelaySeconds ?? self.translationRevealDelaySeconds
            let translationHoldSeconds = translationMinimumVisibleSeconds ?? self.translationMinimumVisibleSeconds
            let lensSeconds = lensUpdateIntervalSeconds ?? self.lensUpdateIntervalSeconds
            let layout = displayLayout ?? self.displayLayout
            let rolling = rollingConfiguration ?? self.rollingConfiguration
            guard (1...4).contains(rolling.sourceLines), (16...40).contains(rolling.columns),
                  (100...200).contains(rolling.englishWidthPercent), rolling.englishWidthPercent % 10 == 0 else {
                error = "原文须占 1–4 行，每行宽度须为 16–40，英文行宽倍率须为 1.0–2.0 倍（每档 0.1）。"
                return false
            }
            guard Self.isValidSeconds(customSeconds, range: 0...30),
                  Self.isValidSeconds(partialSeconds, range: 0...1),
                  Self.isValidSeconds(takeoverSeconds, range: 0...1),
                  Self.isValidSeconds(sourceSeconds, range: 0...3),
                  Self.isValidSeconds(revealSeconds, range: 0...3),
                  Self.isValidSeconds(translationHoldSeconds, range: 0...5),
                  Self.isValidSeconds(lensSeconds, range: 0.5...2) else {
                error = "字幕时序超出允许范围，请检查毫秒输入。"
                return false
            }
            let value = SubtitleDisplayPreferences(mode: mode, order: order, retention: retention,
                                                   showLiveSourceDuringTranslation: liveSource,
                                                   customRetentionSeconds: customSeconds,
                                                   partialUpdateIntervalSeconds: partialSeconds,
                                                   nextSentenceTakeoverDelaySeconds: takeoverSeconds,
                                                   minimumSourceVisibleSeconds: sourceSeconds,
                                                   translationRevealDelaySeconds: revealSeconds,
                                                   translationMinimumVisibleSeconds: translationHoldSeconds,
                                                   lensUpdateIntervalSeconds: lensSeconds,
                                                   displayLayout: layout,
                                                   rollingConfiguration: rolling)
            defaults.set(try JSONEncoder().encode(value), forKey: Self.displayPreferencesKey)
            displayMode = mode
            bilingualOrder = order
            displayRetention = retention
            self.showLiveSourceDuringTranslation = liveSource
            self.customRetentionSeconds = customSeconds
            self.partialUpdateIntervalSeconds = partialSeconds
            self.nextSentenceTakeoverDelaySeconds = takeoverSeconds
            self.minimumSourceVisibleSeconds = sourceSeconds
            self.translationRevealDelaySeconds = revealSeconds
            self.translationMinimumVisibleSeconds = translationHoldSeconds
            self.lensUpdateIntervalSeconds = lensSeconds
            self.displayLayout = layout
            self.rollingConfiguration = rolling
            error = nil
            return true
        } catch {
            self.error = "字幕显示设置未能保存，请重试。"
            return false
        }
    }
    private static func isValidSeconds(_ value: Double, range: ClosedRange<Double>) -> Bool {
        value.isFinite && range.contains(value)
    }
    private static func clampSeconds(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
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
