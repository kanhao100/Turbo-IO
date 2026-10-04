import Foundation
import Combine
import UIKit
import RayNeoProtocol
import RayNeoCaptions

@MainActor protocol SubtitleTranslationClient: AnyObject {
    func translate(_ text: String) async throws -> String
    func cancel()
}

#if COMPANION_DEVICE
extension AppleCaptionTranslation: SubtitleTranslationClient {}
#endif

@MainActor protocol SubtitleRealtimeDevice: AnyObject {
    var supportsDevice: Bool { get }
    var deviceID: String? { get }
    var subtitleOwnsDisplay: Bool { get }
    var voiceEnabled: Bool { get }
    var featureIsBusy: (() -> Bool)? { get }
    func prepare()
    func ownDisplayForSubtitles(_ owns: Bool)
    @discardableResult func sendRealtimeSubtitle(target: String, payload: Data) throws -> String
    func sendDisplaySubtitle(target: String, payload: Data) throws
}

extension SubtitleRealtimeDevice {
    var voiceEnabled: Bool { false }
    // Existing test doubles exercise the glasses-audio protocol only. The real device
    // implements the separate display-only transport and its stricter wire validator.
    func sendDisplaySubtitle(target: String, payload: Data) throws {
        throw SubtitleDisplayWire.Failure.invalidPacket
    }
}

protocol SubtitlePCMDecoder: AnyObject {
    func decode(_ packet: Data) -> Data?
    func reset()
}

#if COMPANION_DEVICE
final class NativeSubtitlePCMDecoder: SubtitlePCMDecoder {
    private let handle: OpaquePointer
    init?() { guard let handle = RNVoiceVADCreate() else { return nil }; self.handle = handle }
    deinit { RNVoiceVADDestroy(handle) }
    func reset() { _ = RNVoiceVADReset(handle) }
    func decode(_ packet: Data) -> Data? {
        guard !packet.isEmpty, packet.count <= 4096 else { return nil }
        var samples = [Int16](repeating: 0, count: 1920)
        let frames = packet.withUnsafeBytes { bytes in
            samples.withUnsafeMutableBufferPointer { buffer in
                RNVoiceDecodePCM(handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                                 bytes.count, buffer.baseAddress, buffer.count)
            }
        }
        // libopus performs the stereo-to-mono downmix. Never take one silent channel.
        guard frames > 0, frames <= 12 else { return nil }
        return samples.withUnsafeBytes { Data($0.prefix(Int(frames) * 320)) }
    }
}
#endif

/// Caption start/result/audio/text/stop all use business 19 and ONE protocol SID.
/// Stops upload and disk input immediately. Glasses-originated stop is authoritative;
/// phone-originated stop releases local ownership after the command is submitted so a
/// missing acknowledgement can never force the user back to the phone.
@MainActor final class SubtitleRealtimeRuntime: ObservableObject {
    enum Phase: String { case idle, preparing, startingAudio, openingDisplay, listening }
    typealias WriterFactory = (URL, SubtitleSessionRecord, @escaping () -> Void) async throws -> SubtitleSessionWriting
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "让眼镜听见的声音，变成看得见的字幕"
    @Published private(set) var partial = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var displaySourceText = ""
    @Published private(set) var displayTranslationText = ""
    @Published private(set) var displayText = ""
    @Published private(set) var displaySourceLines: [String] = []
    @Published private(set) var displayTranslationLines: [String] = []
    @Published private(set) var displayIsPartial = false
    @Published private(set) var displayIsAwaitingTranslation = false
    @Published private(set) var microphoneRoute: String?
    @Published private(set) var recent: [CaptionEntry] = []
    @Published private(set) var elapsed = 0
    @Published private(set) var audioBytes = 0
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var gaps = 0
    @Published private(set) var packets = 0
    @Published private(set) var sessionID: UUID?
    @Published private(set) var lastSavedID: UUID?
    @Published private(set) var error: String?
    @Published private(set) var lastEvent = "尚未开始"
    @Published private(set) var saving = false
    @Published private(set) var shortcutEnabled = false
    @Published private(set) var cloudReady = false
    @Published private(set) var pickupDirectionMessage: String?
    @Published private(set) var pickupDirectionNeedsRetry = false
    @Published private(set) var controlEvents: [String] = []
    let settings: SubtitleSettingsStore
    let archive: SubtitleArchiveStore
    let latency: SubtitleLatencyDiagnostics
    var onShortcutStart: (() -> Void)?
    private let device: any SubtitleRealtimeDevice
    private let defaults: UserDefaults
    private let uptime: () -> TimeInterval
    private let makeDecoder: () -> SubtitlePCMDecoder?
    private let makeWriter: WriterFactory
    private let makeTranslator: ((String, String, SubtitleTranslationQuality) async throws -> any SubtitleTranslationClient)?
    private let scheduleTimers: Bool
    private static let pendingKey = "companion.realtimeSubtitles.exitPending.v1"
    private static let shortcutKey = "companion.realtimeSubtitles.shortcutEnabled.v1"
    private var timer: Timer?, displayTimingTimer: Timer?, lifecycle: NSObjectProtocol?
    private var provider: CaptionASRProvider?, decoder: SubtitlePCMDecoder?, writer: SubtitleSessionWriting?
    #if COMPANION_DEVICE
    private var microphone: SubtitleMicrophoneInput?
    #endif
    private var translator: (any SubtitleTranslationClient)?
    private var record: SubtitleSessionRecord?, options = CaptionOptions(), key = ""
    private var target: String?, sid: String?, generation = UUID()
    private var sessionInputSource: SubtitleInputSource = .glasses
    private var sessionTranslationQuality: SubtitleTranslationQuality = .lowLatency
    private var displayClaimed = false, displayOpening = false, displayDeadline: TimeInterval = 0
    private var translationQueue: Task<Void, Never>?
    private var translatedRecent: [String] = []
    private var sentenceNumber = 0, displayedSentenceNumber = 0
    private var newestRecognizedSentenceNumber = 0
    private struct PendingPartialDisplay {
        let source: String
        let sentence: Int
        let temporarySource: Bool
        let dueAt: TimeInterval
    }
    private struct PendingTranslationReveal {
        let source: String
        let translation: String
        let sentence: Int
        let readyAt: TimeInterval
    }
    private struct PendingFinalDisplay {
        let source: String
        let sentence: Int
        let completed: Bool
        let temporarySource: Bool
    }
    private var pendingPartialDisplay: PendingPartialDisplay?
    private var pendingFinalDisplay: PendingFinalDisplay?
    private var pendingTranslationReveals: [Int: PendingTranslationReveal] = [:]
    private var takeoverSentenceNumber = 0
    private var isProcessingDisplayTransitions = false
    private var partialFirstSeenSentenceNumber = 0
    private var partialFirstSeenAt: TimeInterval = 0
    private var lastPartialPublishedSentenceNumber = 0
    private var lastPartialPublishedAt: TimeInterval = -.infinity
    private var finalSourceShownSentenceNumber = 0
    private var finalSourceShownAt: TimeInterval?
    private var firstPartialAudioBytes: Int?
    private var lastExpiredSentenceNumber = 0
    private var hasCompletedDisplayPair = false
    private var displayShowsTemporarySource = false
    // Phone and lens have separate clocks: the lens deadline starts only after
    // its final type-5 packet has actually been submitted.
    private var displayCompletedAt: TimeInterval?
    private var displayExpiresAt: TimeInterval?
    private var pendingFinalLensSentenceNumber: Int?
    private var lensCompletedSentenceNumber = 0
    private var lensDisplayCompletedAt: TimeInterval?
    private var lensDisplayExpiresAt: TimeInterval?
    private var displayPreferencesSignature = ""
    private var displayLayoutSignature = ""
    private var displayRetentionSignature = ""
    private var pendingTranslations = 0, skippedTranslations = 0
    private var rollingBuffer = CaptionRollingBuffer()
    private var rollingSourceIsPartial = false
    private var rollingPendingSource: (text: String, sentence: Int, final: Bool, dueAt: TimeInterval)?
    private var rollingLastSourcePublishedAt: TimeInterval = -.infinity
    private struct RollingTranslationDelivery {
        let sentence: Int
        let steps: [String]
        var index = 0
        var submitted = false
    }
    private var rollingTranslationDelivery: RollingTranslationDelivery?
    private var rollingLastTranslationSentence = 0
    private var rollingLastTranslationShownAt: TimeInterval = -.infinity
    private var rollingTranslationAwaitingLens = false
    private var rollingLastActivityAt: TimeInterval = -.infinity
    private var reportedLanguageMismatch = false
    private var inputRouteType: String?
    private var lastASRDiagnosticSummary = ""
    private var sessionPickupDirection: SubtitleTranslateWire.PickupDirection = .around
    private var lastPickupDirectionMessageID: String?
    private var pendingPickupDirection: SubtitleTranslateWire.PickupDirection?
    private var deadline: TimeInterval = 0, began: TimeInterval = 0, lastAudioAt: TimeInterval = 0
    private var lastSequence: Int?, gapOpen = false, displayReady = false, cloudStarted = false
    private(set) var sequenceJumps = 0
    private(set) var maximumSequenceStep = 0
    private(set) var discardedSequencePackets = 0
    private(set) var maximumDispatchDelayMilliseconds = 0
    private(set) var maximumArrivalIntervalMilliseconds = 0
    private var sequenceStepCounts: [Int:Int] = [:]
    private var otherSequenceSteps = 0
    private var pendingText: String?, lastDisplayAt: TimeInterval = -.infinity
    private var acceptedAt: TimeInterval = 0, cloudDeadline: TimeInterval = 0
    private var shortcutSuppressedUntil: TimeInterval = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var now: TimeInterval { uptime() }
    var active: Bool { phase != .idle }
    var canStart: Bool {
        guard !active, !saving else { return false }
        if settings.inputSource != .glasses {
            return !device.voiceEnabled && device.featureIsBusy?() != true
        }
        return device.supportsDevice && device.deviceID != nil && !device.subtitleOwnsDisplay && device.featureIsBusy?() != true
    }
    var canStop: Bool { [.preparing, .startingAudio, .openingDisplay, .listening].contains(phase) }
    var currentInputSource: SubtitleInputSource { active ? sessionInputSource : settings.inputSource }
    var glassesOutputReady: Bool { displayReady && target != nil }
    var canChangePickupDirection: Bool {
        settings.allowsChanges && ((phase == .idle && !saving) || (phase == .listening && sessionInputSource == .glasses))
    }
    var audioSeconds: TimeInterval { Double(audioBytes) / 32_000 }

    init(voice: any SubtitleRealtimeDevice, settings: SubtitleSettingsStore, archive: SubtitleArchiveStore,
         defaults: UserDefaults = .standard, makeDecoder: (() -> SubtitlePCMDecoder?)? = nil,
         makeWriter: WriterFactory? = nil, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleTimers: Bool = true, latency: SubtitleLatencyDiagnostics? = nil,
         makeTranslator: ((String, String, SubtitleTranslationQuality) async throws -> any SubtitleTranslationClient)? = nil) {
        device = voice; self.settings = settings; self.archive = archive; self.defaults = defaults
        self.latency = latency ?? SubtitleLatencyDiagnostics(defaults: defaults)
        self.uptime = uptime; self.scheduleTimers = scheduleTimers
        self.makeTranslator = makeTranslator
        self.makeDecoder = makeDecoder ?? {
            #if COMPANION_DEVICE
            return NativeSubtitlePCMDecoder()
            #else
            return nil
            #endif
        }
        self.makeWriter = makeWriter ?? { root, record, failure in
            try await Task.detached(priority: .utility) {
                try CaptionDiskSink(root: root, id: record.id, recordAudio: record.savesAudio, record: record, onFailure: failure)
            }.value
        }
        settings.isBusy = { [weak self] in self?.active == true || self?.saving == true }
        archive.isActive = { [weak self] id in self?.sessionID == id && (self?.active == true || self?.saving == true) }
        shortcutEnabled = defaults.bool(forKey: Self.shortcutKey)
        if defaults.bool(forKey: Self.pendingKey) {
            defaults.removeObject(forKey: Self.pendingKey)
            status = "上次字幕会话异常中断，已自动清理；可直接再次双击启动。"
        }
        lifecycle = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    deinit {
        timer?.invalidate(); displayTimingTimer?.invalidate()
        if let lifecycle { NotificationCenter.default.removeObserver(lifecycle) }
    }
    func prepare() {
        device.prepare(); settings.refresh()
    }
    func setPickupDirection(_ direction: SubtitleTranslateWire.PickupDirection) {
        guard canChangePickupDirection else {
            error = "请等待字幕开始完成或本次保存结束，再切换收音方向。"
            return
        }
        guard direction != settings.pickupDirection else { return }
        if phase == .idle {
            if settings.savePickupDirection(direction) {
                pickupDirectionMessage = "已保存；下次字幕会话将请求\(direction == .ahead ? "前方" : "四周")收音。"
                error = nil
            }
            return
        }
        submitPickupDirection(direction)
    }
    func retryPickupDirection() {
        guard phase == .listening, pickupDirectionNeedsRetry else { return }
        submitPickupDirection(pendingPickupDirection ?? settings.pickupDirection)
    }
    private func submitPickupDirection(_ direction: SubtitleTranslateWire.PickupDirection) {
        guard let sid, let target, device.deviceID == target else {
            connectionChanged()
            pickupDirectionMessage = "眼镜已断开，切换指令未发送。"
            error = "眼镜已断开，收音方向切换指令未发送。"
            return
        }
        do {
            let packet = try SubtitleTranslateWire.syncServiceSettings(sid: sid, direction: direction)
            let messageID = try device.sendRealtimeSubtitle(target: target, payload: packet)
            if settings.savePickupDirection(direction) {
                sessionPickupDirection = direction
                lastPickupDirectionMessageID = messageID
                pendingPickupDirection = nil
                pickupDirectionNeedsRetry = false
                pickupDirectionMessage = "已发送\(direction == .ahead ? "前方" : "四周")收音切换指令；眼镜是否生效待真机确认。"
                controlEvents.append("t=\(String(format: "%.3f", now)) business=19 type=10 direction=\(direction.rawValue) state=submitted packets=\(packets) gaps=\(gaps)")
                controlEvents = Array(controlEvents.suffix(80))
                error = nil
            }
        } catch {
            lastPickupDirectionMessageID = nil
            pendingPickupDirection = direction
            pickupDirectionNeedsRetry = true
            pickupDirectionMessage = "切换到\(direction == .ahead ? "前方" : "四周")的指令未能发送；眼镜当前收音方向未确认。"
            self.error = "收音方向切换失败，请确认眼镜连接后重试。"
            controlEvents.append("t=\(String(format: "%.3f", now)) business=19 type=10 direction=\(direction.rawValue) state=submit_failed packets=\(packets) gaps=\(gaps)")
            controlEvents = Array(controlEvents.suffix(80))
        }
    }
    @discardableResult func start() -> Task<Void, Never>? {
        prepare()
        guard canStart else { error = "请先结束当前会话；使用眼镜收音时还需连接眼镜并退出其他眼镜任务。"; return nil }
        let source = settings.inputSource
        let displayTarget: String? = source == .glasses ? device.deviceID :
            (settings.showOnGlasses && device.supportsDevice && !device.subtitleOwnsDisplay && device.featureIsBusy?() != true
                ? device.deviceID : nil)
        return begin(deviceID: displayTarget, incomingSID: nil, source: source)
    }
    @discardableResult private func begin(deviceID: String?, incomingSID: String?, source: SubtitleInputSource,
                                          incomingArrival: TimeInterval? = nil) -> Task<Void, Never>? {
        guard canStart, let config = settings.recognizer() else {
            error = "请先配置所选转写服务；字幕不需要 DeepSeek。"; return nil
        }
        let decoder: SubtitlePCMDecoder?
        if source == .glasses {
            guard let created = makeDecoder() else { error = "无法创建眼镜音频解码器。"; return nil }
            decoder = created
        } else { decoder = nil }
        generation = UUID(); let token = generation
        let id = UUID(), protocolID = incomingSID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        controlEvents = []
        if let incomingArrival {
            controlEvents.append("t=\(String(format: "%.3f", incomingArrival)) business=19 type=1 sid=current state=received")
        }
        target = deviceID; sid = protocolID; sessionID = id; options = config.options; key = config.key
        sessionInputSource = source
        sessionTranslationQuality = settings.translationQuality
        sessionPickupDirection = settings.pickupDirection; pickupDirectionMessage = nil
        pickupDirectionNeedsRetry = false; lastPickupDirectionMessageID = nil; pendingPickupDirection = nil
        provider = config.provider; self.decoder = decoder; phase = .preparing; status = "正在准备本次字幕与音频存储"
        partial = ""; translatedText = ""; translatedRecent = []; microphoneRoute = nil; inputRouteType = nil
        displaySourceText = ""; displayTranslationText = ""; displayText = ""
        displaySourceLines = []; displayTranslationLines = []
        displayIsPartial = false; displayIsAwaitingTranslation = false
        sentenceNumber = 0; displayedSentenceNumber = 0; lastExpiredSentenceNumber = 0
        newestRecognizedSentenceNumber = 0
        pendingPartialDisplay = nil; pendingFinalDisplay = nil
        pendingTranslationReveals.removeAll(); takeoverSentenceNumber = 0
        isProcessingDisplayTransitions = false
        partialFirstSeenSentenceNumber = 0; partialFirstSeenAt = 0
        lastPartialPublishedSentenceNumber = 0; lastPartialPublishedAt = -.infinity
        finalSourceShownSentenceNumber = 0; finalSourceShownAt = nil
        firstPartialAudioBytes = nil
        hasCompletedDisplayPair = false; displayShowsTemporarySource = false
        displayCompletedAt = nil; displayExpiresAt = nil
        pendingFinalLensSentenceNumber = nil; lensCompletedSentenceNumber = 0
        lensDisplayCompletedAt = nil; lensDisplayExpiresAt = nil
        displayPreferencesSignature = currentDisplayPreferencesSignature
        displayLayoutSignature = currentDisplayLayoutSignature
        displayRetentionSignature = currentDisplayRetentionSignature
        lastASRDiagnosticSummary = ""
        translationQueue?.cancel(); translationQueue = nil
        pendingTranslations = 0; skippedTranslations = 0
        rollingBuffer.reset(); rollingSourceIsPartial = false; rollingPendingSource = nil
        rollingLastSourcePublishedAt = -.infinity; rollingTranslationDelivery = nil
        rollingLastTranslationSentence = 0; rollingLastTranslationShownAt = -.infinity
        rollingTranslationAwaitingLens = false; rollingLastActivityAt = -.infinity
        reportedLanguageMismatch = false
        recent = []; elapsed = 0; audioBytes = 0; audioLevel = 0; packets = 0; gaps = 0
        lastSequence = nil; gapOpen = false; displayReady = false; cloudReady = false; cloudStarted = false
        displayOpening = false; displayDeadline = 0; displayClaimed = false
        sequenceJumps = 0; maximumSequenceStep = 0; discardedSequencePackets = 0
        maximumDispatchDelayMilliseconds = 0; maximumArrivalIntervalMilliseconds = 0
        sequenceStepCounts = [:]; otherSequenceSteps = 0
        lastDisplayAt = -.infinity; pendingText = nil; error = nil; acceptedAt = now; began = now
        let latencyService = options.service == .aliyun
            ? "\(options.service.name) · \(options.aliyunModel.rawValue)" : options.service.name
        latency.sessionStarted(at: now, service: latencyService)
        if source == .glasses { device.ownDisplayForSubtitles(true); displayClaimed = true }
        let value = SubtitleSessionRecord(id: id, title: "字幕 · " + Date().formatted(date: .abbreviated, time: .shortened), options: options)
        record = value
        let makeWriter = makeWriter, root = archive.root
        return Task {
            do {
                #if COMPANION_DEVICE
                if options.service == .appleLocal {
                    status = "正在准备 Apple 本机语音模型"
                    try await AppleLocalCaptionASR.prepare(localeIdentifier: options.language)
                    guard generation == token, phase == .preparing else { return }
                    appendControl("asr_asset=ready")
                }
                #endif
                if settings.translationEnabled {
                    guard options.cloudLanguage != nil else {
                        fail("本机翻译需要先选择固定的识别语言。"); return
                    }
                    let destination = Self.translationTarget(for: options.language)
                    if let makeTranslator {
                        let created = try await makeTranslator(options.language, destination, sessionTranslationQuality)
                        guard generation == token, phase == .preparing else { created.cancel(); return }
                        translator = created
                    } else {
                    #if COMPANION_DEVICE
                    let readiness = await AppleCaptionTranslation.readiness(
                        source: options.language, target: destination,
                        quality: sessionTranslationQuality)
                    guard generation == token, phase == .preparing else { return }
                    guard readiness == .ready else {
                        fail(readiness.message + "请先在字幕设置中准备语言包。"); return
                    }
                    translator = AppleCaptionTranslation(source: options.language, target: destination,
                                                         quality: sessionTranslationQuality)
                    appendControl("translation_asset=ready source=\(options.language) target=\(destination) quality=\(sessionTranslationQuality.rawValue)")
                    #else
                    fail("当前构建不支持本机翻译。"); return
                    #endif
                    }
                }
                #if !COMPANION_DEVICE
                if options.service == .appleLocal {
                    fail("当前构建不支持本机识别或翻译。"); return
                }
                #endif
                let output = try await makeWriter(root, value) { [weak self] in
                    Task { @MainActor in guard let self, self.generation == token else { return }; self.fail("本地保存失败；已收到的原文件保留。") }
                }
                guard generation == token, phase == .preparing else {
                    var cancelled = value; cancelled.state = .interrupted; cancelled.endedAt = Date(); cancelled.endReason = "准备阶段取消，未请求收音"
                    await withCheckedContinuation { continuation in output.finish(cancelled) { _ in continuation.resume() } }
                    return
                }
                writer = output
                if source == .glasses, device.deviceID != deviceID {
                    stop(reason: "准备时眼镜已断开", interrupted: true); return
                }
                writer?.event(CaptionEntry(kind: .started, text: "\(source.name) · \(options.service.name) · \(options.selectedModel) · \(options.language) · \(options.recordAudio ? "保存文本及音频" : "仅保存文本")"))
                defaults.set(true, forKey: Self.pendingKey)
                if source == .glasses {
                    // A local analyzer must be ready before the glasses are asked to stream.
                    if options.service == .appleLocal {
                        startRecognition(token: token)
                        guard await waitForRecognition(token: token, seconds: 20) else { return }
                    }
                    guard generation == token, phase == .preparing else { return }
                    phase = .startingAudio; deadline = now + 10; lastAudioAt = now; began = now
                    installTimer()
                    if incomingSID != nil {
                        guard send(try SubtitleTranslateWire.startResult(sid: protocolID, language: options.glassesLanguage,
                                                                         saveAudio: options.recordAudio, direction: sessionPickupDirection)) else { return }
                        appendControl("business=19 type=2 direction=\(sessionPickupDirection.rawValue) state=submitted")
                        guard generation == token, phase == .startingAudio else { return }
                        acceptedStart(); onShortcutStart?()
                    } else {
                        status = "已请求字幕收音，等待眼镜确认"
                        if send(try SubtitleTranslateWire.start(sid: protocolID, language: options.glassesLanguage,
                                                                saveAudio: options.recordAudio, direction: sessionPickupDirection)) {
                            appendControl("business=19 type=1 direction=\(sessionPickupDirection.rawValue) state=submitted")
                        }
                    }
                } else {
                    startRecognition(token: token)
                    guard await waitForRecognition(token: token, seconds: 20) else { return }
                    guard generation == token, phase == .preparing else { return }
                    await startMicrophone(token: token)
                }
            } catch {
                guard generation == token else { return }
                fail("字幕准备失败：\(error.localizedDescription)")
            }
        }
    }
    private static func translationTarget(for source: String) -> String {
        source == "zh-CN" ? "en-US" : "zh-CN"
    }
    private var sourceIsChinese: Bool { options.language.lowercased().hasPrefix("zh") }
    private var effectiveDisplayMode: SubtitleDisplayMode {
        guard !settings.translationEnabled else { return settings.displayMode }
        // Old installs can retain a translation-dependent mode after translation is disabled.
        // Keep showing recognized speech in its source language rather than a blank caption.
        return sourceIsChinese ? .chineseOnly : .englishOnly
    }
    private var currentDisplayPreferencesSignature: String {
        "\(settings.displayMode.rawValue)|\(settings.bilingualOrder.rawValue)|\(settings.displayRetention.rawValue)|\(settings.customRetentionSeconds)|\(settings.showLiveSourceDuringTranslation)|\(settings.partialUpdateIntervalSeconds)|\(settings.nextSentenceTakeoverDelaySeconds)|\(settings.minimumSourceVisibleSeconds)|\(settings.translationRevealDelaySeconds)|\(settings.lensUpdateIntervalSeconds)|\(settings.displayLayout.rawValue)|\(settings.rollingConfiguration)|\(settings.translationMinimumVisibleSeconds)"
    }
    private var currentDisplayLayoutSignature: String {
        "\(settings.displayMode.rawValue)|\(settings.bilingualOrder.rawValue)|\(settings.showLiveSourceDuringTranslation)|\(settings.displayLayout.rawValue)|\(settings.rollingConfiguration)"
    }
    private var currentDisplayRetentionSignature: String {
        "\(settings.displayRetention.rawValue)|\(settings.effectiveRetentionSeconds.map { String($0) } ?? "next")"
    }
    private func updateDisplayExpiryFromCompletion() {
        displayExpiresAt = displayCompletedAt.flatMap { completedAt in
            settings.effectiveRetentionSeconds.map { completedAt + $0 }
        }
        lensDisplayExpiresAt = lensDisplayCompletedAt.flatMap { completedAt in
            settings.effectiveRetentionSeconds.map { completedAt + $0 }
        }
    }
    private func armDisplayExpiryIfNeeded() {
        // Phone display begins when composed; the lens has a separate deadline
        // that starts after successful type-5 submission.
        guard hasCompletedDisplayPair else { return }
        if displayCompletedAt == nil { displayCompletedAt = now }
        updateDisplayExpiryFromCompletion()
    }
    private var sourceCanShowWithoutTranslation: Bool {
        switch effectiveDisplayMode {
        case .bilingual: return true
        case .chineseOnly: return sourceIsChinese
        case .englishOnly: return !sourceIsChinese
        }
    }
    private var displayNeedsTranslationBeforeCommit: Bool {
        settings.translationEnabled && (effectiveDisplayMode == .bilingual || !sourceCanShowWithoutTranslation)
    }
    private var usesRollingDisplay: Bool { settings.displayLayout == .rolling }
    private var rollingVisibility: (source: Bool, translation: Bool) {
        switch effectiveDisplayMode {
        case .bilingual: return (true, true)
        case .chineseOnly: return (sourceIsChinese, !sourceIsChinese)
        case .englishOnly: return (!sourceIsChinese, sourceIsChinese)
        }
    }
    private func offerRollingSource(_ text: String, sentence: Int, final: Bool) {
        rollingSourceIsPartial = !final
        rollingLastActivityAt = now
        guard final || rollingVisibility.source else { return }
        let due = final ? now : rollingLastSourcePublishedAt + settings.partialUpdateIntervalSeconds
        if due > now {
            rollingPendingSource = (text, sentence, final, due)
            scheduleDisplayWake()
        } else {
            rollingPendingSource = nil
            rollingBuffer.updateSource(text, sentence: sentence, final: final)
            rollingLastSourcePublishedAt = now
            publishRollingDisplay()
        }
    }
    private func publishRollingDisplay() {
        let visibility = rollingVisibility
        let frame = rollingBuffer.snapshot(configuration: settings.rollingConfiguration,
                                           sourceVisible: visibility.source,
                                           translationVisible: visibility.translation)
        let visible = frame.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : frame.text
        displaySourceLines = frame.sourceLines
        displayTranslationLines = frame.translationLines
        displaySourceText = frame.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        displayTranslationText = frame.translationText.trimmingCharacters(in: .whitespacesAndNewlines)
        displayIsPartial = rollingSourceIsPartial && visibility.source
        displayIsAwaitingTranslation = settings.translationEnabled &&
            (pendingTranslations > 0 || !pendingTranslationReveals.isEmpty || rollingTranslationDelivery != nil)
        // A translation step may belong to an older source segment. Both channels
        // remain in this complete frame, so current speech cannot erase that step.
        displayExpiresAt = nil; lensDisplayExpiresAt = nil
        pendingFinalLensSentenceNumber = nil; hasCompletedDisplayPair = false
        if displayText != visible || rollingTranslationAwaitingLens {
            displayText = visible
            pendingText = visible.isEmpty ? " " : frame.text
            if !isProcessingDisplayTransitions { pumpDisplay() }
        }
        scheduleDisplayWake()
    }
    private func processRollingDisplayTransitions() {
        // Sentence layout may already have mirrored these completed translations
        // into the rolling history before a product-workbench mode switch.
        for sentence in pendingTranslationReveals.keys.filter({ $0 <= rollingLastTranslationSentence }) {
            pendingTranslationReveals.removeValue(forKey: sentence)
        }
        if let pending = rollingPendingSource, now >= pending.dueAt {
            rollingPendingSource = nil
            rollingBuffer.updateSource(pending.text, sentence: pending.sentence, final: pending.final)
            rollingLastSourcePublishedAt = now
            publishRollingDisplay()
        }
        let hold = settings.translationMinimumVisibleSeconds
        if !rollingTranslationAwaitingLens, now >= rollingLastTranslationShownAt + hold {
            if let delivery = rollingTranslationDelivery, delivery.submitted {
                if delivery.index + 1 < delivery.steps.count {
                    var next = delivery; next.index += 1; next.submitted = false
                    rollingTranslationDelivery = next
                } else { rollingTranslationDelivery = nil }
            }
            if rollingTranslationDelivery == nil,
               let ready = pendingTranslationReveals.values
                .filter({ $0.sentence > rollingLastTranslationSentence &&
                          now >= $0.readyAt + settings.translationRevealDelaySeconds })
                .min(by: { $0.sentence < $1.sentence }) {
                pendingTranslationReveals.removeValue(forKey: ready.sentence)
                let steps = CaptionRollingBuffer.translationSteps(ready.translation,
                                                                  configuration: settings.rollingConfiguration)
                if !steps.isEmpty {
                    rollingTranslationDelivery = RollingTranslationDelivery(sentence: ready.sentence, steps: steps)
                }
            }
            if var delivery = rollingTranslationDelivery, !delivery.submitted {
                let final = delivery.index == delivery.steps.count - 1
                rollingBuffer.updateTranslation(delivery.steps[delivery.index], sentence: delivery.sentence, final: final)
                if final { rollingLastTranslationSentence = max(rollingLastTranslationSentence, delivery.sentence) }
                delivery.submitted = true; rollingTranslationDelivery = delivery
                rollingLastActivityAt = now
                // Start reading time after submission to an active lens. Without
                // a lens, phone presentation starts the same clock immediately.
                rollingTranslationAwaitingLens = target != nil && rollingVisibility.translation
                if !rollingTranslationAwaitingLens { rollingLastTranslationShownAt = now }
                publishRollingDisplay()
                appendControl("display_state=rolling_translation sentence=\(delivery.sentence) step=\(delivery.index + 1)/\(delivery.steps.count)")
            }
        }
        if let retention = settings.effectiveRetentionSeconds, !rollingSourceIsPartial,
           pendingTranslations == 0, pendingTranslationReveals.isEmpty,
           rollingTranslationDelivery == nil, rollingPendingSource == nil,
           !displayText.isEmpty, now >= rollingLastActivityAt + retention {
            rollingBuffer.reset()
            publishRollingDisplay()
            appendControl("display_state=rolling_expired")
        }
    }
    private func composedDisplayText(source: String, translation: String,
                                     temporarySource: Bool = false) -> String {
        if temporarySource { return source }
        switch effectiveDisplayMode {
        case .chineseOnly: return sourceIsChinese ? source : translation
        case .englishOnly: return sourceIsChinese ? translation : source
        case .bilingual:
            guard !translation.isEmpty else { return source }
            return settings.bilingualOrder == .sourceFirst
                ? source + "\n" + translation : translation + "\n" + source
        }
    }
    private func lensDisplayText(source: String, translation: String,
                                 temporarySource: Bool = false) -> String {
        if temporarySource { return CaptionText.lensWindow(source, maximumBytes: 384) }
        if effectiveDisplayMode == .bilingual, !translation.isEmpty {
            // Give each language its own budget so tail truncation cannot erase one line.
            let first = CaptionText.lensWindow(source, maximumBytes: 180)
            let second = CaptionText.lensWindow(translation, maximumBytes: 180)
            return settings.bilingualOrder == .sourceFirst
                ? first + "\n" + second : second + "\n" + first
        }
        return CaptionText.lensWindow(composedDisplayText(source: source, translation: translation), maximumBytes: 384)
    }
    private func showDisplay(source: String, translation: String, partial: Bool,
                             completed: Bool, sentence: Int,
                             temporarySource: Bool = false) {
        guard sentence >= newestRecognizedSentenceNumber,
              sentence >= displayedSentenceNumber, sentence > lastExpiredSentenceNumber else {
            if completed { appendControl("display_state=late_result_ignored") }
            return
        }
        let visible = composedDisplayText(source: source, translation: translation,
                                          temporarySource: temporarySource)
        guard !visible.isEmpty else { return }
        let visualChange = visible != displayText || sentence != displayedSentenceNumber ||
            partial != displayIsPartial || completed != hasCompletedDisplayPair ||
            temporarySource != displayShowsTemporarySource
        displayedSentenceNumber = sentence
        displaySourceText = source
        displayTranslationText = translation
        displayText = visible
        displayIsPartial = partial
        displayIsAwaitingTranslation = !partial && !completed && settings.translationEnabled
        displayShowsTemporarySource = temporarySource
        hasCompletedDisplayPair = completed
        if !partial, !completed, settings.translationEnabled {
            finalSourceShownSentenceNumber = sentence
            finalSourceShownAt = now
        }
        if visualChange {
            displayCompletedAt = nil; displayExpiresAt = nil
            lensDisplayCompletedAt = nil; lensDisplayExpiresAt = nil
            lensCompletedSentenceNumber = 0
            pendingFinalLensSentenceNumber = completed ? sentence : nil
            if completed { armDisplayExpiryIfNeeded() }
        }
        guard visualChange else { return }
        if partial {
            lastPartialPublishedSentenceNumber = sentence
            lastPartialPublishedAt = now
        }
        pendingText = lensDisplayText(source: source, translation: translation,
                                      temporarySource: temporarySource)
        appendControl("display_state=updated mode=\(effectiveDisplayMode.rawValue) pair=\(completed) partial=\(partial) temporarySource=\(temporarySource)")
        if !isProcessingDisplayTransitions { pumpDisplay() }
        scheduleDisplayWake()
    }
    private func offerPartialDisplay(source: String, sentence: Int, temporarySource: Bool) {
        if partialFirstSeenSentenceNumber != sentence {
            partialFirstSeenSentenceNumber = sentence
            partialFirstSeenAt = now
            if sentence > displayedSentenceNumber, !displayText.isEmpty {
                takeoverSentenceNumber = sentence
            }
        }
        let takeoverDeadline = takeoverDeadline(for: sentence)
        let updateDeadline = lastPartialPublishedSentenceNumber == sentence
            ? lastPartialPublishedAt + settings.partialUpdateIntervalSeconds : now
        let due = max(takeoverDeadline, updateDeadline)
        if due <= now {
            pendingPartialDisplay = nil
            claimDisplayForSentence(sentence)
            showDisplay(source: source, translation: "", partial: true,
                        completed: false, sentence: sentence,
                        temporarySource: temporarySource)
        } else {
            pendingPartialDisplay = PendingPartialDisplay(
                source: source, sentence: sentence, temporarySource: temporarySource, dueAt: due)
            scheduleDisplayWake()
        }
    }
    private func takeoverDeadline(for sentence: Int) -> TimeInterval {
        // A missing gate must be a stable past deadline. Returning a fresh `now`
        // here makes two comparisons in the same turn disagree and can spin timers.
        guard takeoverSentenceNumber == sentence, !displayText.isEmpty else { return -.infinity }
        return partialFirstSeenAt + settings.nextSentenceTakeoverDelaySeconds
    }
    private func offerFinalSourceDisplay(source: String, sentence: Int,
                                         completed: Bool, temporarySource: Bool = false) {
        let pending = PendingFinalDisplay(source: source, sentence: sentence,
                                          completed: completed,
                                          temporarySource: temporarySource)
        if takeoverDeadline(for: sentence) > now {
            pendingFinalDisplay = pending
            appendControl("display_state=final_waits_for_takeover sentence=\(sentence)")
            scheduleDisplayWake()
        } else {
            _ = deliverPendingFinalIfAllowed(pending)
        }
    }
    private func currentFinalDisplayPlan(for pending: PendingFinalDisplay)
        -> (completed: Bool, temporarySource: Bool)? {
        let completed = !displayNeedsTranslationBeforeCommit
        let canShowSource = completed ||
            (settings.showLiveSourceDuringTranslation && settings.translationEnabled) ||
            (effectiveDisplayMode == .bilingual && pending.sentence == 1 && !hasCompletedDisplayPair)
        guard canShowSource else { return nil }
        let temporarySource = !completed && !sourceCanShowWithoutTranslation
        guard !composedDisplayText(source: pending.source, translation: "",
                                   temporarySource: temporarySource).isEmpty else { return nil }
        return (completed, temporarySource)
    }
    @discardableResult private func deliverPendingFinalIfAllowed(_ pending: PendingFinalDisplay) -> Bool {
        guard let plan = currentFinalDisplayPlan(for: pending) else {
            appendControl("display_state=pending_final_hidden_by_mode")
            return false
        }
        claimDisplayForSentence(pending.sentence)
        showDisplay(source: pending.source, translation: "", partial: false,
                    completed: plan.completed, sentence: pending.sentence,
                    temporarySource: plan.temporarySource)
        return true
    }
    private func claimDisplayForSentence(_ sentence: Int) {
        guard sentence > newestRecognizedSentenceNumber else { return }
        newestRecognizedSentenceNumber = sentence
        if takeoverSentenceNumber <= sentence { takeoverSentenceNumber = 0 }
        if let pending = pendingFinalDisplay, pending.sentence <= sentence { pendingFinalDisplay = nil }
        if let pending = pendingPartialDisplay, pending.sentence <= sentence { pendingPartialDisplay = nil }
        let oldReveals = pendingTranslationReveals.keys.filter { $0 < sentence }
        if !oldReveals.isEmpty {
            for key in oldReveals { pendingTranslationReveals.removeValue(forKey: key) }
            appendControl("display_state=old_translation_cancelled_by_new_display")
        }
        if let pendingFinal = pendingFinalLensSentenceNumber, pendingFinal < sentence {
            pendingFinalLensSentenceNumber = nil
            pendingText = nil
            appendControl("display_state=old_lens_final_cancelled_by_new_display")
        }
    }
    private func translationRevealDeadline(for value: PendingTranslationReveal) -> TimeInterval {
        let sourceDeadline = finalSourceShownSentenceNumber == value.sentence
            ? (finalSourceShownAt ?? value.readyAt) + settings.minimumSourceVisibleSeconds
            : value.readyAt
        return max(max(sourceDeadline, value.readyAt + settings.translationRevealDelaySeconds),
                   takeoverDeadline(for: value.sentence))
    }
    private func offerTranslationReveal(source: String, translation: String, sentence: Int) {
        if usesRollingDisplay {
            guard sentence > rollingLastTranslationSentence else { return }
            if !rollingVisibility.translation {
                if let delivery = rollingTranslationDelivery, delivery.sentence < sentence {
                    rollingBuffer.appendTranslation(delivery.steps.last ?? "", sentence: delivery.sentence)
                    rollingTranslationDelivery = nil
                    rollingTranslationAwaitingLens = false
                }
                for ready in pendingTranslationReveals.values
                    .filter({ $0.sentence < sentence }).sorted(by: { $0.sentence < $1.sentence }) {
                    rollingBuffer.appendTranslation(ready.translation, sentence: ready.sentence)
                    pendingTranslationReveals.removeValue(forKey: ready.sentence)
                }
                rollingBuffer.appendTranslation(translation, sentence: sentence)
                rollingLastTranslationSentence = max(rollingLastTranslationSentence, sentence)
                publishRollingDisplay()
                return
            }
            if translation.isEmpty {
                publishRollingDisplay()
                return
            }
            pendingTranslationReveals[sentence] = PendingTranslationReveal(
                source: source, translation: translation, sentence: sentence, readyAt: now)
            processDisplayTransitions()
            return
        }
        if !translation.isEmpty {
            rollingBuffer.appendTranslation(translation, sentence: sentence)
            rollingLastActivityAt = now
            rollingLastTranslationSentence = max(rollingLastTranslationSentence, sentence)
            if let delivery = rollingTranslationDelivery, delivery.sentence <= sentence {
                rollingTranslationDelivery = nil
            }
        }
        guard sentence >= newestRecognizedSentenceNumber,
              sentence >= displayedSentenceNumber, sentence > lastExpiredSentenceNumber else {
            appendControl("display_state=late_translation_ignored")
            return
        }
        let value = PendingTranslationReveal(
            source: source, translation: translation, sentence: sentence, readyAt: now)
        if translationRevealDeadline(for: value) <= now {
            claimDisplayForSentence(sentence)
            showDisplay(source: source, translation: translation, partial: false,
                        completed: true, sentence: sentence)
        } else {
            pendingTranslationReveals[sentence] = value
            appendControl("display_state=translation_reveal_scheduled sentence=\(sentence)")
            scheduleDisplayWake()
        }
    }
    private func processDisplayTransitions() {
        isProcessingDisplayTransitions = true
        defer {
            isProcessingDisplayTransitions = false
            pumpDisplay()
            scheduleDisplayWake()
        }
        if usesRollingDisplay {
            processRollingDisplayTransitions()
            return
        }
        if let displayExpiresAt, now >= displayExpiresAt { clearVisibleDisplay() }
        if let pending = pendingFinalDisplay,
           takeoverDeadline(for: pending.sentence) <= now {
            pendingFinalDisplay = nil
            _ = deliverPendingFinalIfAllowed(pending)
        }
        if let pending = pendingPartialDisplay, now >= pending.dueAt {
            pendingPartialDisplay = nil
            if pending.sentence == sentenceNumber + 1 {
                claimDisplayForSentence(pending.sentence)
                showDisplay(source: pending.source, translation: "", partial: true,
                            completed: false, sentence: pending.sentence,
                            temporarySource: pending.temporarySource)
            }
        }
        let dueReveals = pendingTranslationReveals.values
            .filter { now >= translationRevealDeadline(for: $0) }
        if !dueReveals.isEmpty {
            for pending in dueReveals {
                pendingTranslationReveals.removeValue(forKey: pending.sentence)
            }
            // Only the newest eligible result from this timer turn reaches the
            // outputs. Older results are archived but cannot consume a lens slot.
            if let pending = dueReveals
                .filter({ $0.sentence >= newestRecognizedSentenceNumber &&
                           $0.sentence >= displayedSentenceNumber &&
                           $0.sentence > lastExpiredSentenceNumber })
                .max(by: { $0.sentence < $1.sentence }) {
                claimDisplayForSentence(pending.sentence)
                showDisplay(source: pending.source, translation: pending.translation,
                            partial: false, completed: true, sentence: pending.sentence)
            }
        }
        if let lensDisplayExpiresAt, now >= lensDisplayExpiresAt { expireLensDisplay() }
    }
    private func clearVisibleDisplay() {
        guard !displayText.isEmpty else { return }
        lastExpiredSentenceNumber = displayedSentenceNumber
        displaySourceText = ""; displayTranslationText = ""; displayText = ""
        displayIsPartial = false; displayIsAwaitingTranslation = false
        hasCompletedDisplayPair = false; displayShowsTemporarySource = false
        displayCompletedAt = nil; displayExpiresAt = nil
        takeoverSentenceNumber = 0
        // The phone may expire before a throttled final type-5 reaches the lens.
        // Preserve that packet until submitted; the lens uses its own expiry clock.
        if pendingFinalLensSentenceNumber == nil, lensDisplayExpiresAt == nil,
           target != nil, displayReady {
            // No final packet is outstanding, so a blank can be sent now.
            pendingText = " "
        }
        appendControl("display_state=phone_expired")
        if let pending = pendingFinalDisplay,
           pending.sentence == sentenceNumber {
            pendingFinalDisplay = nil
            if deliverPendingFinalIfAllowed(pending) { return }
        }
        if let pending = pendingPartialDisplay,
           pending.sentence == sentenceNumber + 1 {
            // Once the old caption expires there is nothing left to protect with a
            // takeover delay. Show the latest partial instead of leaving a blank gap.
            pendingPartialDisplay = nil
            claimDisplayForSentence(pending.sentence)
            showDisplay(source: pending.source, translation: "", partial: true,
                        completed: false, sentence: pending.sentence,
                        temporarySource: pending.temporarySource)
            return
        }
        if !isProcessingDisplayTransitions { pumpDisplay() }
        scheduleDisplayWake()
    }
    private func expireLensDisplay() {
        guard lensDisplayExpiresAt != nil else { return }
        lensDisplayCompletedAt = nil; lensDisplayExpiresAt = nil
        lensCompletedSentenceNumber = 0
        // Type-5 rejects an empty payload. A single space visually clears the lens.
        if target != nil, displayReady { pendingText = " " }
        appendControl("display_state=lens_expired")
        if !isProcessingDisplayTransitions { pumpDisplay() }
        scheduleDisplayWake()
    }
    private func refreshDisplayPreferences() {
        let signature = currentDisplayPreferencesSignature
        guard signature != displayPreferencesSignature else { return }
        let retentionSignature = currentDisplayRetentionSignature
        let retentionChanged = retentionSignature != displayRetentionSignature
        let layoutSignature = currentDisplayLayoutSignature
        let layoutChanged = layoutSignature != displayLayoutSignature
        displayPreferencesSignature = signature
        displayLayoutSignature = layoutSignature
        displayRetentionSignature = retentionSignature
        if usesRollingDisplay {
            pendingPartialDisplay = nil; pendingFinalDisplay = nil
            displayExpiresAt = nil; lensDisplayExpiresAt = nil
            pendingFinalLensSentenceNumber = nil
            if let pending = rollingPendingSource {
                rollingPendingSource = nil
                offerRollingSource(pending.text, sentence: pending.sentence, final: pending.final)
            }
            publishRollingDisplay()
            return
        }
        rollingPendingSource = nil
        rollingTranslationAwaitingLens = false
        if retentionChanged { updateDisplayExpiryFromCompletion() }
        let liveSource = settings.showLiveSourceDuringTranslation && settings.translationEnabled
        let strictFirstSource = sourceCanShowWithoutTranslation &&
            (!displayNeedsTranslationBeforeCommit ||
             (sentenceNumber == 0 && lastExpiredSentenceNumber == 0 &&
              pendingTranslations == 0 && !hasCompletedDisplayPair))
        if let pending = pendingPartialDisplay {
            if liveSource || strictFirstSource {
                // A product-tuning edit takes effect for a partial already waiting.
                offerPartialDisplay(source: pending.source, sentence: pending.sentence,
                                    temporarySource: !sourceCanShowWithoutTranslation)
            } else {
                pendingPartialDisplay = nil
            }
        }
        if let pending = pendingFinalDisplay {
            if let plan = currentFinalDisplayPlan(for: pending) {
                pendingFinalDisplay = PendingFinalDisplay(
                    source: pending.source, sentence: pending.sentence,
                    completed: plan.completed, temporarySource: plan.temporarySource)
            } else {
                pendingFinalDisplay = nil
                appendControl("display_state=pending_final_cancelled_by_mode")
            }
        }
        if !liveSource, !strictFirstSource, pendingFinalDisplay == nil {
            // No partial or final source will claim the screen in strict mode.
            // Its translation is governed only by reveal/minimum-source timing.
            takeoverSentenceNumber = 0
        }
        guard layoutChanged else { scheduleDisplayWake(); return }
        guard !displaySourceText.isEmpty || !displayTranslationText.isEmpty else {
            scheduleDisplayWake()
            return
        }
        if !settings.showLiveSourceDuringTranslation { displayShowsTemporarySource = false }
        let visible = composedDisplayText(source: displaySourceText,
                                          translation: displayTranslationText,
                                          temporarySource: displayShowsTemporarySource)
        if visible.isEmpty {
            // Switching to a translation-only layout can temporarily have no
            // translated text. Hide the source without expiring this sentence;
            // its pending translation must still be allowed to appear.
            displayText = ""
            displayIsPartial = false
            displayIsAwaitingTranslation = settings.translationEnabled
            hasCompletedDisplayPair = false
            displayCompletedAt = nil; displayExpiresAt = nil
            lensDisplayCompletedAt = nil; lensDisplayExpiresAt = nil
            lensCompletedSentenceNumber = 0; pendingFinalLensSentenceNumber = nil
            finalSourceShownSentenceNumber = 0; finalSourceShownAt = nil
            if let pending = pendingPartialDisplay {
                pendingPartialDisplay = nil
                claimDisplayForSentence(pending.sentence)
                showDisplay(source: pending.source, translation: "", partial: true,
                            completed: false, sentence: pending.sentence,
                            temporarySource: pending.temporarySource)
                return
            }
            if target != nil { pendingText = " " }
            appendControl("display_state=hidden_by_mode_change")
            pumpDisplay()
            scheduleDisplayWake()
            return
        }
        displayText = visible
        // Repaint only when layout changes. Timing edits keep each output's
        // original completion timestamp and do not submit duplicate type-5 packets.
        pendingText = lensDisplayText(source: displaySourceText,
                                      translation: displayTranslationText,
                                      temporarySource: displayShowsTemporarySource)
        pendingFinalLensSentenceNumber = hasCompletedDisplayPair &&
            lensCompletedSentenceNumber != displayedSentenceNumber ? displayedSentenceNumber : nil
        appendControl("display_state=preferences_changed mode=\(effectiveDisplayMode.rawValue) retentionChanged=\(retentionChanged)")
        pumpDisplay()
        scheduleDisplayWake()
    }
    private func appendControl(_ event: String) {
        controlEvents.append("t=\(String(format: "%.3f", now)) \(event)")
        controlEvents = Array(controlEvents.suffix(80))
    }
    private func startRecognition(token: UUID) {
        guard generation == token, !cloudStarted else { return }
        provider?.onReady = { [weak self] in
            guard let self, self.generation == token, self.cloudStarted else { return }
            self.cloudReady = true
            self.latency.cloudReady(at: self.now)
            self.appendControl("asr_state=ready")
        }
        provider?.onText = { [weak self] text, final in
            guard let self, self.generation == token else { return }
            self.recognized(text, final: final)
        }
        provider?.onFailure = { [weak self] failure in
            guard let self, self.generation == token else { return }
            self.appendControl("asr_state=failed")
            self.fail("\(self.options.service.name)：\(failure.message)")
        }
        provider?.onEndpoint = nil
        #if COMPANION_DEVICE
        if let local = provider as? AppleLocalCaptionASR {
            local.onDiagnostic = { [weak self] event in
                guard let self, self.generation == token else { return }
                self.appendControl(event)
            }
        }
        #endif
        cloudStarted = true
        cloudDeadline = now + 20
        latency.cloudStarted(at: now)
        appendControl("asr_state=starting service=\(options.service.rawValue)")
        provider?.start(options: options, key: key)
    }
    private func waitForRecognition(token: UUID, seconds: TimeInterval) async -> Bool {
        let until = now + seconds
        while generation == token, phase == .preparing, !cloudReady, now < until {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard generation == token, phase == .preparing else { return false }
        guard cloudReady else {
            fail("转写引擎准备超时，请检查模型或服务连接。"); return false
        }
        return true
    }
    private func startMicrophone(token: UUID) async {
        #if COMPANION_DEVICE
        guard sessionInputSource != .glasses, generation == token else { return }
        let mic = SubtitleMicrophoneInput()
        microphone = mic
        mic.onDiagnostic = { [weak self] event in
            guard let self, self.generation == token else { return }
            // AVAudioSession error descriptions and port names are not part of shared diagnostics.
            let safe = event.components(separatedBy: " error=").first ?? event
            self.appendControl(safe.hasPrefix("mic.failure=") ? "mic.failure" : safe)
        }
        mic.onFailure = { [weak self] reason in
            guard let self, self.generation == token else { return }
            self.appendControl("mic_state=failed")
            self.fail(reason)
        }
        mic.onPCM = { [weak self] pcm in
            guard let self, self.generation == token else { return }
            self.acceptMicrophonePCM(pcm)
        }
        do {
            let preferredUID: String?
            if sessionInputSource == .iPhoneMicrophone {
                let ports = try await SubtitleMicrophoneInput.availablePorts()
                preferredUID = ports.first(where: { $0.isBuiltIn })?.uid
                guard preferredUID != nil else {
                    fail("当前没有可用的 iPhone 内置麦克风。"); return
                }
            } else { preferredUID = settings.systemInputUID }
            guard generation == token, phase == .preparing else { return }
            status = "正在打开\(sessionInputSource.name)"
            began = now; lastAudioAt = now
            latency.audioStartAccepted(at: now)
            let port = try await mic.start(preferredUID: preferredUID)
            guard generation == token, phase == .preparing else { mic.stop(); return }
            microphoneRoute = port.name
            inputRouteType = port.type
            appendControl("mic_state=ready type=\(port.type) source=\(sessionInputSource.rawValue)")
            phase = .listening; deadline = 0; installTimer()
            status = "正在听 · \(port.name) · \(options.service.name)"
            if target != nil { openDisplayOnly() }
            else if settings.showOnGlasses {
                appendControl("display_state=unavailable phone_capture=continues")
                status = "正在听 · \(port.name) · 仅手机显示"
            }
        } catch {
            guard generation == token else { return }
            appendControl("mic_state=start_failed")
            fail(error.localizedDescription)
        }
        #else
        fail("此构建没有麦克风采集功能。")
        #endif
    }
    private func acceptMicrophonePCM(_ pcm: Data) {
        guard sessionInputSource != .glasses, cloudStarted,
              phase == .preparing || phase == .listening else { return }
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 16_384 else {
            fail("麦克风 PCM 数据格式不正确。"); return
        }
        let arrival = now
        if packets > 0 {
            let interval = arrival - lastAudioAt
            maximumArrivalIntervalMilliseconds = max(maximumArrivalIntervalMilliseconds, Int(interval * 1_000))
            if interval > 0.75 { markGap("麦克风音频到达间隔中断") }
        }
        latency.audioArrived(callbackAt: arrival, handledAt: now)
        lastAudioAt = arrival; packets += 1; audioBytes += pcm.count
        record?.receivedPCMBytes = audioBytes
        if gapOpen { writer?.event(CaptionEntry(kind: .gap, text: "麦克风音频恢复，缺失部分未补录")); gapOpen = false }
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        audioLevel = min(1, sqrt(samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(samples.count)) * 5)
        writer?.pcm(pcm)
        // Cloud and Apple adapters accept bounded frames. Keep disk input intact.
        for offset in stride(from: 0, to: pcm.count, by: 3_840) {
            provider?.append(pcm.subdata(in: offset..<min(offset + 3_840, pcm.count)))
        }
    }
    private func openDisplayOnly() {
        guard sessionInputSource != .glasses, let sid, let target, device.deviceID == target,
              !device.subtitleOwnsDisplay, device.featureIsBusy?() != true else {
            dropDisplayOnly(reason: "眼镜显示不可用", notifyGlasses: false)
            return
        }
        device.ownDisplayForSubtitles(true); displayClaimed = true
        guard device.deviceID == target else { dropDisplayOnly(reason: "连接已变化", notifyGlasses: false); return }
        displayOpening = true; displayDeadline = now + 10
        do {
            try device.sendDisplaySubtitle(target: target, payload: SubtitleDisplayWire.preview(sid: sid))
            appendControl("business=19 type=7 display_only=1 state=submitted")
        } catch { dropDisplayOnly(reason: "眼镜显示配置未能发送", notifyGlasses: false) }
    }
    private func dropDisplayOnly(reason: String, notifyGlasses: Bool) {
        guard sessionInputSource != .glasses else { return }
        if notifyGlasses, let target, let sid, device.deviceID == target,
           let packet = try? SubtitleDisplayWire.stop(sid: sid) {
            try? device.sendDisplaySubtitle(target: target, payload: packet)
            appendControl("business=19 type=3 display_only=1 state=submitted")
        }
        displayOpening = false; displayReady = false; displayDeadline = 0; pendingText = nil
        pendingFinalLensSentenceNumber = nil; lensCompletedSentenceNumber = 0
        lensDisplayCompletedAt = nil; lensDisplayExpiresAt = nil
        target = nil
        if rollingTranslationAwaitingLens {
            rollingTranslationAwaitingLens = false
            rollingLastTranslationShownAt = now
            scheduleDisplayWake()
        }
        if displayExpiresAt == nil { armDisplayExpiryIfNeeded() }
        if displayClaimed { device.ownDisplayForSubtitles(false); displayClaimed = false }
        appendControl("display_state=disabled reason=\(reason) phone_capture=continues")
        if phase == .listening {
            status = "正在听 · \(microphoneRoute ?? sessionInputSource.name) · 仅手机显示（眼镜显示不可用）"
        }
    }
    func setShortcut(_ enabled: Bool) {
        guard !active, !saving else { return }
        settings.refresh()
        guard !enabled || settings.inputSource == .glasses else {
            error = "眼镜双击仅适用于眼镜音频流。"; return
        }
        guard !enabled || settings.requirements.isEmpty else { error = "请先保存转写配置与密钥。"; return }
        shortcutEnabled = enabled
        defaults.set(enabled, forKey: Self.shortcutKey)
        error = nil
    }
    func receive(device source: String, packet: Data, arrival: TimeInterval) {
        // `arrival` is captured in the native callback. A bounded main-queue delay must not
        // silently discard valid audio; session/device/SID/acceptance-time checks reject stale work.
        guard source == device.deviceID, now >= arrival else { return }
        if active, sessionInputSource != .glasses {
            guard displayClaimed, source == target, arrival >= acceptedAt else { return }
            guard let reply = try? SubtitleDisplayWire.reply(packet) else {
                dropDisplayOnly(reason: "显示回包格式不正确", notifyGlasses: true); return
            }
            if reply.type == 4 {
                // Display-only output never consumes or archives glasses audio.
                appendControl("business=19 type=4 display_only=1 state=unexpected")
                dropDisplayOnly(reason: "显示会话收到非预期眼镜音频", notifyGlasses: true)
                return
            }
            guard reply.sid == sid else { return }
            if reply.type == 8, displayOpening {
                guard reply.code == 1 || reply.code == 2 else {
                    dropDisplayOnly(reason: "眼镜未接受显示配置", notifyGlasses: true); return
                }
                displayOpening = false; displayReady = true
                appendControl("business=19 type=8 display_only=1 state=accepted")
                status = "正在听 · \(microphoneRoute ?? sessionInputSource.name) · 手机和眼镜显示"
                pumpDisplay()
            } else if reply.type == 3 {
                dropDisplayOnly(reason: "眼镜结束显示", notifyGlasses: false)
            }
            return
        }
        guard let event = try? SubtitleTranslateWire.event(packet) else {
            if active, source == target { fail("字幕消息格式或音频长度不匹配，已停止本次会话。") }
            return
        }
        if [1, 2, 3, 7, 8, 10].contains(event.type) {
            let state = active ? phase.rawValue : (saving ? "saving" : "idle")
            let sidMatch = event.sid == sid ? "current" : "other"
            let code = event.code.map { " code=\($0)" } ?? ""
            controlEvents.append("t=\(String(format: "%.3f", arrival)) business=19 type=\(event.type) sid=\(sidMatch) state=\(state)\(code)")
            controlEvents = Array(controlEvents.suffix(80))
        }
        // A second glasses shortcut uses the same type-1 control event as the first one on
        // current firmware. Handle it before strict SID filtering: its new SID is a gesture
        // identifier and must never replace the active caption SID.
        if active, sessionInputSource == .glasses, event.type == 1, source == target, arrival >= acceptedAt {
            guard arrival - acceptedAt >= 1.5 else {
                lastEvent = "忽略字幕启动后的重复 type=1（防抖）"
                return
            }
            lastEvent = "收到第二次眼镜双击，停止当前字幕"
            shortcutSuppressedUntil = now + 1.5
            stop(reason: "眼镜再次双击，已停止并保存", interrupted: false, notifyGlasses: true)
            return
        }
        if phase == .idle, event.type == 1 {
            guard shortcutEnabled, settings.inputSource == .glasses else { return }
            guard !saving, arrival >= shortcutSuppressedUntil else {
                status = "上一段正在保存或仍在防抖期；请稍后再次双击"
                return
            }
            guard canStart else { return }
            _ = begin(deviceID: source, incomingSID: event.sid, source: .glasses,
                      incomingArrival: arrival); return
        }
        guard active, source == target, event.sid == sid, arrival >= acceptedAt else { return }
        if (phase == .startingAudio || phase == .openingDisplay), now >= deadline {
            fail("字幕握手回应已超时，未根据迟到回包重新开启收音。")
            return
        }
        if event.type == 3 {
            // The matching glasses control event is the authoritative exit signal. Stop through
            // the same idempotent path as the phone button; a short cooldown rejects tail events.
            stop(reason: "眼镜已停止字幕（\(event.reason.map(String.init) ?? "未提供原因")）",
                 interrupted: false, notifyGlasses: false)
            return
        }
        guard canStop, phase != .preparing else { return }
        if event.type == 2, phase == .startingAudio {
            guard event.code == 1 else { fail("眼镜未接受字幕启动，code=\(event.code.map(String.init) ?? "无效")。请检查冲突、佩戴和电量。"); return }
            acceptedStart()
        } else if event.type == 8, phase == .openingDisplay {
            guard event.code == 1 || event.code == 2 else { fail("眼镜未接受字幕显示配置。" ); return }
            displayReady = true; phase = .listening
            status = options.service == .aliyun
                ? "正在听 · \(options.aliyunModel.name)" : "正在听 · \(options.service.name)"
            pumpDisplay()
        } else if event.type == 4, cloudStarted, phase == .openingDisplay || phase == .listening {
            acceptAudio(event, arrival: arrival)
        }
    }
    private func acceptedStart() {
        guard phase == .startingAudio, let sid else { return }
        phase = .openingDisplay; deadline = now + 10; lastAudioAt = now
        latency.audioStartAccepted(at: now)
        status = "收音启动已确认，正在连接转写与字幕显示"
        let token = generation
        startRecognition(token: token)
        guard generation == token, phase == .openingDisplay else { return }
        do { _ = send(try SubtitleTranslateWire.display(sid: sid)) } catch { fail("无法编码显示命令。") }
    }
    private func acceptAudio(_ event: SubtitleTranslateWire.Event, arrival: TimeInterval) {
        guard let sequence = event.sequence else { return }
        if event.audio == nil, event.end { stop(reason: "眼镜音频已结束"); return }
        maximumDispatchDelayMilliseconds = max(maximumDispatchDelayMilliseconds, Int((now - arrival) * 1_000))
        guard packets == 0 || arrival >= lastAudioAt else { discardedSequencePackets += 1; return }
        if let previous = lastSequence {
            guard sequence > previous else { discardedSequencePackets += 1; return }
            let step = sequence - previous
            maximumSequenceStep = max(maximumSequenceStep, step)
            if sequenceStepCounts[step] != nil || sequenceStepCounts.count < 8 {
                sequenceStepCounts[step, default: 0] += 1
            } else { otherSequenceSteps += 1 }
            if step != 1 {
                // Current glasses firmware does not expose `seq` as a guaranteed +1 packet
                // counter. Keep the bounded aggregate for diagnosis, but never manufacture an
                // audio gap or rotate a WAV solely from an undocumented numeric stride.
                sequenceJumps += 1
            }
        }
        lastSequence = sequence
        if packets > 0 {
            let interval = arrival - lastAudioAt
            maximumArrivalIntervalMilliseconds = max(maximumArrivalIntervalMilliseconds, Int(interval * 1_000))
            if interval > 0.75 { markGap("音频到达间隔中断") }
        }
        guard let audio = event.audio, let pcm = decoder?.decode(audio), !pcm.isEmpty, pcm.count <= 3840, pcm.count % 2 == 0 else {
            markGap("音频包未通过 Opus 解码校验"); fail("眼镜字幕音频格式未通过解码；请分享诊断记录。") ; return
        }
        latency.audioArrived(callbackAt: arrival, handledAt: now)
        lastAudioAt = arrival; packets += 1; audioBytes += pcm.count
        record?.receivedPCMBytes = audioBytes
        if gapOpen { writer?.event(CaptionEntry(kind: .gap, text: "音频恢复，缺失部分未补录")); gapOpen = false }
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        audioLevel = min(1, sqrt(samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(samples.count)) * 5)
        writer?.pcm(pcm); provider?.append(pcm)
        if event.end { stop(reason: "眼镜音频已结束") }
    }
    private func recognized(_ value: String, final: Bool) {
        guard cloudStarted, phase == .openingDisplay || phase == .listening else { return }
        guard value.utf8.count <= 32768 else { fail("单句转写超过保存上限。" ); return }
        latency.resultReceived(at: now)
        cloudReady = true; partial = value
        if !value.isEmpty {
            rollingSourceIsPartial = !final
            rollingLastActivityAt = now
        }
        if final {
            if !value.isEmpty {
                if options.service == .appleLocal, !reportedLanguageMismatch,
                   let detected = LocalSubtitleLanguageDetection.detect(sampleText: value),
                   LocalSubtitleLanguageDetection.differsFromConfiguredLocale(
                       detected, configuredLocale: options.language) {
                    reportedLanguageMismatch = true
                    appendControl("asr_text_language_mismatch detected=\(detected.language.rawValue) configured=\(sourceIsChinese ? "chinese" : "english")")
                }
                // Recognition callbacks trail the spoken words. Keep a short lead-in
                // from the first partial so tapping a sentence does not skip its start.
                let seekBytes = firstPartialAudioBytes ?? max(0, audioBytes - 96_000)
                let audioOffset = Double(seekBytes) / 32_000
                let entry = CaptionEntry(kind: .final, text: value, audioOffset: audioOffset); recent.append(entry)
                if recent.count > 200 { recent.removeFirst(recent.count - 200) }
                record?.finalSentences += 1; record?.preview = String(value.prefix(180)); writer?.event(entry)
                sentenceNumber += 1
                let sentence = sentenceNumber
                pendingPartialDisplay = nil
                if usesRollingDisplay {
                    offerRollingSource(value, sentence: sentence, final: true)
                    queueTranslation(value, sentence: sentence, audioOffset: audioOffset)
                    firstPartialAudioBytes = nil; partial = ""
                    return
                }
                rollingBuffer.updateSource(value, sentence: sentence, final: true)
                if !displayNeedsTranslationBeforeCommit {
                    offerFinalSourceDisplay(source: value, sentence: sentence,
                                            completed: true)
                } else if settings.showLiveSourceDuringTranslation ||
                            (effectiveDisplayMode == .bilingual && sentence == 1 && !hasCompletedDisplayPair) {
                    // Keep the recognized original visible while its final translation runs.
                    // A short utterance still obeys the configured takeover gate.
                    offerFinalSourceDisplay(source: value, sentence: sentence,
                                            completed: false,
                                            temporarySource: !sourceCanShowWithoutTranslation)
                }
                queueTranslation(value, sentence: sentence, audioOffset: audioOffset)
            }
            firstPartialAudioBytes = nil
            partial = ""
        } else if !value.isEmpty {
            let sentence = sentenceNumber + 1
            if usesRollingDisplay {
                if firstPartialAudioBytes == nil { firstPartialAudioBytes = max(0, audioBytes - 96_000) }
                offerRollingSource(value, sentence: sentence, final: false)
                return
            }
            rollingBuffer.updateSource(value, sentence: sentence, final: false)
            let liveSource = settings.showLiveSourceDuringTranslation && settings.translationEnabled
            let firstSourceInStrictMode = sourceCanShowWithoutTranslation &&
                (!displayNeedsTranslationBeforeCommit ||
                 (sentenceNumber == 0 && lastExpiredSentenceNumber == 0 &&
                  pendingTranslations == 0 && !hasCompletedDisplayPair))
            // A pending takeover delay or strict translation layout leaves the
            // previous sentence in charge until this partial is actually shown.
            if firstPartialAudioBytes == nil {
                firstPartialAudioBytes = max(0, audioBytes - 96_000)
            }
            if liveSource {
                // New live speech takes precedence over an older translated sentence.
                // In translation-only mode the original is explicitly temporary; the
                // final translation still replaces it in the selected language.
                offerPartialDisplay(source: value, sentence: sentence,
                                    temporarySource: !sourceCanShowWithoutTranslation)
            } else if firstSourceInStrictMode {
                // Strict translation mode allows the first bilingual utterance to
                // appear while it is recognized. Later utterances wait for their
                // translations even when the previous caption has timed out.
                offerPartialDisplay(source: value, sentence: sentence,
                                    temporarySource: false)
            }
        }
    }
    private func showTranslationFallback(source: String, sentence: Int) {
        switch effectiveDisplayMode {
        case .bilingual:
            appendControl("display_state=source_fallback translation_unavailable=1")
            offerTranslationReveal(source: source, translation: "", sentence: sentence)
        case .chineseOnly, .englishOnly:
            guard !sourceCanShowWithoutTranslation else { return }
            let placeholder = effectiveDisplayMode == .chineseOnly
                ? "本句翻译暂不可用" : "Translation unavailable"
            appendControl("display_state=translation_placeholder mode=\(effectiveDisplayMode.rawValue)")
            // This is display state only. Never archive it as a fabricated translation.
            offerTranslationReveal(source: source, translation: placeholder,
                                   sentence: sentence)
        }
    }
    private func queueTranslation(_ source: String, sentence: Int, audioOffset: TimeInterval) {
        guard settings.translationEnabled else { return }
        guard translator != nil else {
            error = effectiveDisplayMode == .bilingual
                ? "本机翻译尚未就绪，此句仅显示原文；原文已保存。"
                : "本机翻译尚未就绪，此句翻译暂不可用；原文已保存。"
            appendControl("translation_state=unavailable")
            showTranslationFallback(source: source, sentence: sentence)
            return
        }
        let readyDeliveries = usesRollingDisplay
            ? pendingTranslationReveals.count + (rollingTranslationDelivery == nil ? 0 : 1) : 0
        guard pendingTranslations + readyDeliveries < 16 else {
            skippedTranslations += 1
            appendControl("translation_state=backpressure skipped=\(skippedTranslations)")
            error = effectiveDisplayMode == .bilingual
                ? "本机翻译处理积压，此句仅显示原文；原文已保存。"
                : "本机翻译处理积压，此句翻译暂不可用；原文已保存。"
            if usesRollingDisplay {
                // Retain the last readable translation. Do not enqueue another
                // placeholder into the already full ready/display queue.
                publishRollingDisplay()
                return
            }
            showTranslationFallback(source: source, sentence: sentence)
            return
        }
        pendingTranslations += 1
        if usesRollingDisplay { publishRollingDisplay() }
        let previous = translationQueue, token = generation
        translationQueue = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.pendingTranslations = max(0, self.pendingTranslations - 1)
                    if self.usesRollingDisplay { self.publishRollingDisplay() }
                }
            }
            await previous?.value
            guard self.generation == token, self.active, !Task.isCancelled,
                  let translator = self.translator else { return }
            do {
                let translated = try await translator.translate(source)
                guard self.generation == token, self.active, !Task.isCancelled else { return }
                guard !translated.isEmpty, translated.utf8.count <= 32_768 else {
                    self.appendControl("translation_state=empty_or_oversize")
                    self.error = self.effectiveDisplayMode == .bilingual
                        ? "本机翻译未返回可用内容，此句仅显示原文；原文已保存。"
                        : "本机翻译未返回可用内容，此句翻译暂不可用；原文已保存。"
                    self.showTranslationFallback(source: source, sentence: sentence)
                    return
                }
                self.translatedText = translated
                self.translatedRecent.append(translated)
                if self.translatedRecent.count > 200 {
                    self.translatedRecent.removeFirst(self.translatedRecent.count - 200)
                }
                self.writer?.event(CaptionEntry(kind: .translation, text: translated,
                                                audioOffset: audioOffset))
                self.appendControl("translation_state=ready source=\(self.options.language) target=\(Self.translationTarget(for: self.options.language))")
                self.offerTranslationReveal(source: source, translation: translated,
                                            sentence: sentence)
            } catch {
                guard self.generation == token, self.active else { return }
                self.appendControl("translation_state=failed")
                self.error = self.effectiveDisplayMode == .bilingual
                    ? "本机翻译失败，此句仅显示原文；原文已保存。"
                    : "本机翻译失败，此句翻译暂不可用；原文已保存。"
                self.showTranslationFallback(source: source, sentence: sentence)
            }
        }
    }
    private func pumpDisplay() {
        let lensInterval = max(0.5, settings.lensUpdateIntervalSeconds)
        guard phase == .listening, displayReady, target != nil,
              now - lastDisplayAt >= lensInterval, let text = pendingText, let sid else {
            scheduleDisplayWake()
            return
        }
        guard let target, device.deviceID == target else {
            // A disconnected display is terminal for this output. Do not spin on
            // an already-due packet deadline while waiting for a matching device.
            connectionChanged()
            return
        }
        let submittedFinalSentence = pendingFinalLensSentenceNumber
        var submitted = false
        if sessionInputSource == .glasses {
            do {
                if send(try SubtitleTranslateWire.text(text, sid: sid)) {
                    submitted = true; latency.resultSubmittedToGlasses(at: now)
                }
            } catch { fail("无法编码字幕文字。") }
        } else {
            do {
                try device.sendDisplaySubtitle(target: target, payload: SubtitleDisplayWire.text(text, sid: sid))
                submitted = true
                latency.resultSubmittedToGlasses(at: now)
            } catch { dropDisplayOnly(reason: "字幕文字未能发送", notifyGlasses: true) }
        }
        if submitted {
            pendingText = nil
            pendingFinalLensSentenceNumber = nil
            lastDisplayAt = now
            if usesRollingDisplay, rollingTranslationAwaitingLens {
                rollingTranslationAwaitingLens = false
                rollingLastTranslationShownAt = now
            }
        }
        if submitted, let sentence = submittedFinalSentence, text != " " {
            lensCompletedSentenceNumber = sentence
            lensDisplayCompletedAt = now
            updateDisplayExpiryFromCompletion()
            appendControl("display_state=lens_final_submitted sentence=\(sentence)")
        }
        scheduleDisplayWake()
    }
    private func markGap(_ note: String) {
        guard !gapOpen else { return }; gapOpen = true; gaps += 1; record?.gaps = gaps
        firstPartialAudioBytes = nil
        writer?.gap(); decoder?.reset(); writer?.event(CaptionEntry(kind: .gap, text: note))
    }
    func inputLost() { if sessionInputSource == .glasses, cloudStarted { markGap("手机接收队列丢包") } }
    func connectionChanged() {
        guard active, let target, device.deviceID != target else { return }
        if sessionInputSource == .glasses {
            stop(reason: "连接中断，本次字幕已停止并保存", interrupted: true, notifyGlasses: false)
        } else { dropDisplayOnly(reason: "眼镜连接中断", notifyGlasses: false) }
    }
    func transportFailed(device source: String, packet: Data, code: Int, messageID: String) {
        guard source == target else { return }
        if sessionInputSource != .glasses {
            guard let reply = try? SubtitleDisplayWire.reply(packet), reply.sid == sid else { return }
            appendControl("business=19 type=\(reply.type) display_only=1 state=send_failed code=\(code)")
            dropDisplayOnly(reason: "眼镜显示发送失败", notifyGlasses: false)
            return
        }
        guard let event = try? SubtitleTranslateWire.event(packet), event.sid == sid else { return }
        if event.type == 10 {
            let latest = !messageID.isEmpty && messageID == lastPickupDirectionMessageID
            let state = latest ? "send_failed" : "stale_send_failed"
            controlEvents.append("t=\(String(format: "%.3f", now)) business=19 type=10 direction=\(pickupDirection(in: packet)) state=\(state) code=\(code) packets=\(packets) gaps=\(gaps)")
            controlEvents = Array(controlEvents.suffix(80))
            if latest {
                pendingPickupDirection = sessionPickupDirection
                pickupDirectionNeedsRetry = true
                pickupDirectionMessage = "切换指令异步发送失败；眼镜当前收音方向未确认。"
                error = "收音方向切换失败，code=\(code)。可重试或结束后重新启动字幕。"
            }
            return
        }
        if event.type != 3 { fail("字幕命令异步发送失败，code=\(code)") }
    }
    private func pickupDirection(in packet: Data) -> String {
        guard let json = try? BusinessEnvelopeMetadata.messageJSON(packet),
              let body = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let settings = body["settings"] as? [String: Any],
              let raw = settings["direction"] as? String,
              let direction = SubtitleTranslateWire.PickupDirection(rawValue: raw) else { return "unknown" }
        return direction.rawValue
    }
    private func send(_ packet: Data) -> Bool {
        guard let target, device.deviceID == target else { fail("眼镜连接已变化。" ); return false }
        do { try device.sendRealtimeSubtitle(target: target, payload: packet); return true }
        catch { fail("字幕命令未能提交，请确认眼镜状态。" ); return false }
    }
    private func fail(_ reason: String) {
        appendControl("runtime_state=failed source=\(sessionInputSource.rawValue)")
        error = reason; stop(reason: reason, interrupted: true)
    }
    func stop(reason: String = "用户停止", interrupted: Bool = false, notifyGlasses: Bool = true) {
        guard canStop else { return }
        let wasPreparing = phase == .preparing
        let wasGlassesCapture = sessionInputSource == .glasses
        shortcutSuppressedUntil = max(shortcutSuppressedUntil, now + 1.5)
        generation = UUID(); status = reason
        translationQueue?.cancel(); translationQueue = nil
        pendingPartialDisplay = nil; pendingFinalDisplay = nil
        pendingTranslationReveals.removeAll(); takeoverSentenceNumber = 0
        isProcessingDisplayTransitions = false
        displayTimingTimer?.invalidate(); displayTimingTimer = nil
        pendingTranslations = 0
        rollingPendingSource = nil; rollingTranslationDelivery = nil
        rollingTranslationAwaitingLens = false
        translator?.cancel(); translator = nil
        #if COMPANION_DEVICE
        microphone?.stop(); microphone = nil
        #endif
        lastASRDiagnosticSummary = provider?.diagnosticSummary ?? lastASRDiagnosticSummary
        cloudStarted = false; provider?.stop(); provider = nil; key = ""; cloudReady = false; pendingText = nil
        latency.sessionStopped()
        decoder = nil; audioLevel = 0
        if !partial.isEmpty { writer?.event(CaptionEntry(kind: .unfinished, text: partial)); partial = "" }
        var exitSubmissionFailed = false
        if notifyGlasses, !wasPreparing, let sid, let target, device.deviceID == target {
            do {
                if wasGlassesCapture {
                    try device.sendRealtimeSubtitle(target: target, payload: SubtitleTranslateWire.stop(sid: sid))
                    appendControl("business=19 type=3 source=glasses state=submitted")
                } else if displayClaimed {
                    try device.sendDisplaySubtitle(target: target, payload: SubtitleDisplayWire.stop(sid: sid))
                    appendControl("business=19 type=3 display_only=1 state=submitted")
                }
            }
            catch { exitSubmissionFailed = true }
        }
        finishStorage(reason: reason, interrupted: interrupted)
        defaults.removeObject(forKey: Self.pendingKey)
        release()
        if exitSubmissionFailed {
            error = wasGlassesCapture
                ? "眼镜退出命令未送达；本机已停止并保存，可在眼镜再次双击退出后重试。"
                : "眼镜显示退出命令未送达；手机收音已停止并保存，请确认眼镜显示已退出。"
        }
        status = saving ? "字幕已停止，正在完成本机保存" : "字幕已结束，历史保存在此 App"
    }
    private func finishStorage(reason: String, interrupted: Bool) {
        guard let writer, var value = record else { return }
        self.writer = nil; value.endedAt = Date(); value.endReason = reason
        value.state = interrupted || gaps > 0 ? .interrupted : .completed
        writer.event(CaptionEntry(kind: .stopped, text: reason)); saving = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Subtitle archive flush") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        writer.finish(value) { [weak self] success in
            guard let self else { return }; self.saving = false; self.lastSavedID = value.id
            if self.phase == .idle { self.sessionID = nil }
            if !success { self.error = "存储收尾未完整完成；已收到的原文件保留。" }
            self.endBackgroundTask(); Task { await self.archive.load() }
        }
    }
    private func release() {
        timer?.invalidate(); timer = nil
        displayTimingTimer?.invalidate(); displayTimingTimer = nil
        phase = .idle; target = nil; sid = nil
        lastPickupDirectionMessageID = nil; pickupDirectionNeedsRetry = false; pickupDirectionMessage = nil
        pendingPickupDirection = nil
        displayOpening = false; displayReady = false; displayDeadline = 0
        record = nil
        if displayClaimed { device.ownDisplayForSubtitles(false); displayClaimed = false }
        if !saving { sessionID = nil }
    }
    func tick() {
        guard active else { return }
        if let target, device.deviceID != target {
            connectionChanged()
            if !active { return }
        }
        guard canStop, phase != .preparing else { return }
        elapsed = max(0, Int(now - began))
        if sessionInputSource == .glasses,
           (phase == .startingAudio || phase == .openingDisplay), now >= deadline {
            fail("10 秒未收到匹配的字幕启动或显示回执。"); return
        }
        if sessionInputSource != .glasses, displayOpening, now >= displayDeadline {
            dropDisplayOnly(reason: "眼镜显示回应超时", notifyGlasses: true)
        }
        if elapsed >= options.maximumSeconds { stop(reason: "达到本次时长上限"); return }
        if cloudStarted, now - lastAudioAt >= 15 {
            fail(sessionInputSource == .glasses ? "15 秒未收到有效眼镜音频；不是静音。" : "15 秒未收到有效麦克风音频，请检查录音权限和输入设备。"); return
        }
        if cloudStarted, now - lastAudioAt >= 5 {
            markGap(sessionInputSource == .glasses ? "等待眼镜音频恢复" : "等待麦克风音频恢复")
        }
        if cloudStarted, !cloudReady, now >= cloudDeadline { fail("转写连接超时，请检查服务配置和网络。" ); return }
        refreshDisplayPreferences()
        processDisplayTransitions()
        pumpDisplay()
        scheduleDisplayWake()
    }
    private func installTimer() {
        timer?.invalidate(); timer = nil
        guard scheduleTimers else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        scheduleDisplayWake()
    }
    private func scheduleDisplayWake() {
        displayTimingTimer?.invalidate(); displayTimingTimer = nil
        guard scheduleTimers, active else { return }
        var deadlines: [TimeInterval] = []
        if usesRollingDisplay {
            if let pending = rollingPendingSource { deadlines.append(pending.dueAt) }
            if !rollingTranslationAwaitingLens {
                let nextReadingSlot = rollingLastTranslationShownAt + settings.translationMinimumVisibleSeconds
                if rollingTranslationDelivery != nil { deadlines.append(nextReadingSlot) }
                else if let first = pendingTranslationReveals.values
                    .filter({ $0.sentence > rollingLastTranslationSentence })
                    .map({ $0.readyAt + settings.translationRevealDelaySeconds }).min() {
                    deadlines.append(max(first, nextReadingSlot))
                }
            }
            if let retention = settings.effectiveRetentionSeconds, !rollingSourceIsPartial,
               pendingTranslations == 0, pendingTranslationReveals.isEmpty,
               rollingTranslationDelivery == nil, rollingPendingSource == nil,
               !displayText.isEmpty {
                deadlines.append(rollingLastActivityAt + retention)
            }
        } else {
        if let pendingPartialDisplay { deadlines.append(pendingPartialDisplay.dueAt) }
        if let pendingFinalDisplay {
            deadlines.append(takeoverDeadline(for: pendingFinalDisplay.sentence))
        }
        deadlines.append(contentsOf: pendingTranslationReveals.values.map {
            translationRevealDeadline(for: $0)
        })
        if let displayExpiresAt { deadlines.append(displayExpiresAt) }
        if let lensDisplayExpiresAt { deadlines.append(lensDisplayExpiresAt) }
        }
        if pendingText != nil, sid != nil, let target, device.deviceID == target,
           phase == .listening, displayReady {
            deadlines.append(lastDisplayAt + max(0.5, settings.lensUpdateIntervalSeconds))
        }
        guard let next = deadlines.min() else { return }
        // Deadlines have millisecond precision in settings. Main-run-loop scheduling and
        // the glasses transport still determine actual presentation latency.
        let timer = Timer(timeInterval: max(0.001, next - now), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        displayTimingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    var diagnosticText: String {
        let steps = sequenceStepCounts.keys.sorted().map { "\($0):\(sequenceStepCounts[$0] ?? 0)" }.joined(separator: ",")
        let controls = controlEvents.isEmpty ? "none" : controlEvents.joined(separator: "\n")
        let requestedDirection = active ? sessionPickupDirection : settings.pickupDirection
        let asrSummary = provider?.diagnosticSummary ?? lastASRDiagnosticSummary
        let timingMilliseconds: (Double) -> Int = { Int(($0 * 1_000).rounded()) }
        let retention = settings.effectiveRetentionSeconds.map { String(timingMilliseconds($0)) } ?? "next_sentence"
        return "Turbo IO 实时字幕\nphase=\(phase.rawValue) inputSource=\(sessionInputSource.rawValue) inputRouteType=\(inputRouteType ?? "none") displayOpening=\(displayOpening) displayReady=\(displayReady)\npackets=\(packets) pcmBytes=\(audioBytes) gaps=\(gaps)\nseqStrideChanges=\(sequenceJumps) maxSeqStep=\(maximumSequenceStep) discardedSeq=\(discardedSequencePackets)\nseqSteps=\(steps.isEmpty ? "none" : steps) otherSteps=\(otherSequenceSteps)\nmaxArrivalMs=\(maximumArrivalIntervalMilliseconds) maxDispatchMs=\(maximumDispatchDelayMilliseconds)\nASR=\(options.service.name) model=\(options.selectedModel) ready=\(cloudReady) directionRequested=\(requestedDirection.rawValue) translationEnabled=\(settings.translationEnabled) translationQuality=\(sessionTranslationQuality.rawValue) displayMode=\(effectiveDisplayMode.rawValue) retention=\(settings.displayRetention.rawValue) retentionMs=\(retention) liveSourceDuringTranslation=\(settings.showLiveSourceDuringTranslation)\npartialUpdateMs=\(timingMilliseconds(settings.partialUpdateIntervalSeconds)) takeoverMs=\(timingMilliseconds(settings.nextSentenceTakeoverDelaySeconds)) minSourceMs=\(timingMilliseconds(settings.minimumSourceVisibleSeconds)) revealMs=\(timingMilliseconds(settings.translationRevealDelaySeconds)) lensIntervalMs=\(timingMilliseconds(max(0.5, settings.lensUpdateIntervalSeconds)))\n\(asrSummary)\ncontrolEvents:\n\(controls)\n不包含音频、正文、密钥、原始序号或设备标识。"
    }
}
