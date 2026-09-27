import Foundation
import Combine
import UIKit
import RayNeoProtocol
import RayNeoCaptions

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
    @Published private(set) var displayIsPartial = false
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
    private let scheduleTimers: Bool
    private static let pendingKey = "companion.realtimeSubtitles.exitPending.v1"
    private static let shortcutKey = "companion.realtimeSubtitles.shortcutEnabled.v1"
    private var timer: Timer?, lifecycle: NSObjectProtocol?
    private var provider: CaptionASRProvider?, decoder: SubtitlePCMDecoder?, writer: SubtitleSessionWriting?
    #if COMPANION_DEVICE
    private var microphone: SubtitleMicrophoneInput?
    private var translator: AppleCaptionTranslation?
    #endif
    private var record: SubtitleSessionRecord?, options = CaptionOptions(), key = ""
    private var target: String?, sid: String?, generation = UUID()
    private var sessionInputSource: SubtitleInputSource = .glasses
    private var displayClaimed = false, displayOpening = false, displayDeadline: TimeInterval = 0
    private var translationQueue: Task<Void, Never>?
    private var translatedRecent: [String] = []
    private var sentenceNumber = 0, displayedSentenceNumber = 0
    private var lastExpiredSentenceNumber = 0
    private var hasCompletedDisplayPair = false
    private var displayExpiresAt: TimeInterval?
    private var displayPreferencesSignature = ""
    private var pendingTranslations = 0, skippedTranslations = 0
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
         scheduleTimers: Bool = true, latency: SubtitleLatencyDiagnostics? = nil) {
        device = voice; self.settings = settings; self.archive = archive; self.defaults = defaults
        self.latency = latency ?? SubtitleLatencyDiagnostics(defaults: defaults)
        self.uptime = uptime; self.scheduleTimers = scheduleTimers
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
    deinit { timer?.invalidate(); if let lifecycle { NotificationCenter.default.removeObserver(lifecycle) } }
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
        sessionPickupDirection = settings.pickupDirection; pickupDirectionMessage = nil
        pickupDirectionNeedsRetry = false; lastPickupDirectionMessageID = nil; pendingPickupDirection = nil
        provider = config.provider; self.decoder = decoder; phase = .preparing; status = "正在准备本次字幕与音频存储"
        partial = ""; translatedText = ""; translatedRecent = []; microphoneRoute = nil; inputRouteType = nil
        displaySourceText = ""; displayTranslationText = ""; displayText = ""; displayIsPartial = false
        sentenceNumber = 0; displayedSentenceNumber = 0; lastExpiredSentenceNumber = 0
        hasCompletedDisplayPair = false
        displayExpiresAt = nil; displayPreferencesSignature = currentDisplayPreferencesSignature
        lastASRDiagnosticSummary = ""
        translationQueue?.cancel(); translationQueue = nil
        pendingTranslations = 0; skippedTranslations = 0
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
                if settings.translationEnabled {
                    guard options.cloudLanguage != nil else {
                        fail("本机翻译需要先选择固定的识别语言。"); return
                    }
                    let destination = Self.translationTarget(for: options.language)
                    let readiness = await AppleCaptionTranslation.readiness(source: options.language, target: destination)
                    guard generation == token, phase == .preparing else { return }
                    guard readiness == .ready else {
                        fail(readiness.message + "请先在字幕设置中准备语言包。"); return
                    }
                    translator = AppleCaptionTranslation(source: options.language, target: destination)
                    appendControl("translation_asset=ready source=\(options.language) target=\(destination)")
                }
                #else
                if options.service == .appleLocal || settings.translationEnabled {
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
        "\(settings.displayMode.rawValue)|\(settings.bilingualOrder.rawValue)|\(settings.displayRetention.rawValue)"
    }
    private func armDisplayExpiryIfNeeded() {
        // With an intended lens target, wait for a successful type-5 submission.
        // Otherwise a delayed type-8 ACK could consume the entire display duration.
        guard hasCompletedDisplayPair, target == nil else { return }
        displayExpiresAt = settings.displayRetention.seconds.map { now + $0 }
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
    private func composedDisplayText(source: String, translation: String) -> String {
        switch effectiveDisplayMode {
        case .chineseOnly: return sourceIsChinese ? source : translation
        case .englishOnly: return sourceIsChinese ? translation : source
        case .bilingual:
            guard !translation.isEmpty else { return source }
            return settings.bilingualOrder == .sourceFirst
                ? source + "\n" + translation : translation + "\n" + source
        }
    }
    private func lensDisplayText(source: String, translation: String) -> String {
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
                             completed: Bool, sentence: Int) {
        guard sentence >= displayedSentenceNumber, sentence > lastExpiredSentenceNumber else { return }
        let visible = composedDisplayText(source: source, translation: translation)
        guard !visible.isEmpty else { return }
        let visualChange = visible != displayText || sentence != displayedSentenceNumber || partial != displayIsPartial
        displayedSentenceNumber = sentence
        displaySourceText = source
        displayTranslationText = translation
        displayText = visible
        displayIsPartial = partial
        hasCompletedDisplayPair = completed
        if visualChange {
            displayExpiresAt = nil
            if completed { armDisplayExpiryIfNeeded() }
        }
        guard visualChange else { return }
        pendingText = lensDisplayText(source: source, translation: translation)
        appendControl("display_state=updated mode=\(effectiveDisplayMode.rawValue) pair=\(completed) partial=\(partial)")
        pumpDisplay()
    }
    private func clearVisibleDisplay() {
        guard !displayText.isEmpty else { return }
        lastExpiredSentenceNumber = displayedSentenceNumber
        displaySourceText = ""; displayTranslationText = ""; displayText = ""
        displayIsPartial = false; hasCompletedDisplayPair = false; displayExpiresAt = nil
        // Type-5 requires a nonempty string. A single space requests a visually blank lens.
        pendingText = " "
        appendControl("display_state=expired")
        pumpDisplay()
    }
    private func refreshDisplayPreferences() {
        let signature = currentDisplayPreferencesSignature
        guard signature != displayPreferencesSignature else { return }
        displayPreferencesSignature = signature
        guard !displaySourceText.isEmpty || !displayTranslationText.isEmpty else { return }
        let visible = composedDisplayText(source: displaySourceText, translation: displayTranslationText)
        displayText = visible
        displayExpiresAt = nil
        armDisplayExpiryIfNeeded()
        pendingText = visible.isEmpty ? " " : lensDisplayText(source: displaySourceText, translation: displayTranslationText)
        appendControl("display_state=preferences_changed mode=\(effectiveDisplayMode.rawValue)")
        pumpDisplay()
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
        target = nil
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
        if final {
            if !value.isEmpty {
                let entry = CaptionEntry(kind: .final, text: value); recent.append(entry)
                if recent.count > 200 { recent.removeFirst(recent.count - 200) }
                record?.finalSentences += 1; record?.preview = String(value.prefix(180)); writer?.event(entry)
                sentenceNumber += 1
                let sentence = sentenceNumber
                if !displayNeedsTranslationBeforeCommit {
                    showDisplay(source: value, translation: "", partial: false,
                                completed: true, sentence: sentence)
                }
                queueTranslation(value, sentence: sentence)
            }
            partial = ""
        } else if !value.isEmpty, sourceCanShowWithoutTranslation,
                  (!hasCompletedDisplayPair || !displayNeedsTranslationBeforeCommit),
                  (!displayNeedsTranslationBeforeCommit || pendingTranslations == 0) {
            // Translation-dependent displays hold the completed pair until the next
            // translation is ready. Source-only displays can advance with live speech.
            showDisplay(source: value, translation: "", partial: true,
                        completed: false, sentence: sentenceNumber + 1)
        }
    }
    private func showTranslationFallback(source: String, sentence: Int) {
        switch effectiveDisplayMode {
        case .bilingual:
            appendControl("display_state=source_fallback translation_unavailable=1")
            showDisplay(source: source, translation: "", partial: false,
                        completed: true, sentence: sentence)
        case .chineseOnly, .englishOnly:
            guard !sourceCanShowWithoutTranslation else { return }
            let placeholder = effectiveDisplayMode == .chineseOnly
                ? "本句翻译暂不可用" : "Translation unavailable"
            appendControl("display_state=translation_placeholder mode=\(effectiveDisplayMode.rawValue)")
            // This is display state only. Never archive it as a fabricated translation.
            showDisplay(source: source, translation: placeholder, partial: false,
                        completed: true, sentence: sentence)
        }
    }
    private func queueTranslation(_ source: String, sentence: Int) {
        #if COMPANION_DEVICE
        guard settings.translationEnabled else { return }
        guard translator != nil else {
            error = effectiveDisplayMode == .bilingual
                ? "本机翻译尚未就绪，此句仅显示原文；原文已保存。"
                : "本机翻译尚未就绪，此句翻译暂不可用；原文已保存。"
            appendControl("translation_state=unavailable")
            showTranslationFallback(source: source, sentence: sentence)
            return
        }
        guard pendingTranslations < 16 else {
            skippedTranslations += 1
            appendControl("translation_state=backpressure skipped=\(skippedTranslations)")
            error = effectiveDisplayMode == .bilingual
                ? "本机翻译处理积压，此句仅显示原文；原文已保存。"
                : "本机翻译处理积压，此句翻译暂不可用；原文已保存。"
            showTranslationFallback(source: source, sentence: sentence)
            return
        }
        pendingTranslations += 1
        let previous = translationQueue, token = generation
        translationQueue = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.pendingTranslations = max(0, self.pendingTranslations - 1) }
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
                self.writer?.event(CaptionEntry(kind: .translation, text: translated))
                self.appendControl("translation_state=ready source=\(self.options.language) target=\(Self.translationTarget(for: self.options.language))")
                self.showDisplay(source: source, translation: translated, partial: false,
                                 completed: true, sentence: sentence)
            } catch {
                guard self.generation == token, self.active else { return }
                self.appendControl("translation_state=failed")
                self.error = self.effectiveDisplayMode == .bilingual
                    ? "本机翻译失败，此句仅显示原文；原文已保存。"
                    : "本机翻译失败，此句翻译暂不可用；原文已保存。"
                self.showTranslationFallback(source: source, sentence: sentence)
            }
        }
        #endif
    }
    private func pumpDisplay() {
        guard phase == .listening, displayReady, now - lastDisplayAt >= 0.5, let text = pendingText, let sid else { return }
        pendingText = nil; lastDisplayAt = now
        var submitted = false
        if sessionInputSource == .glasses {
            do {
                if send(try SubtitleTranslateWire.text(text, sid: sid)) {
                    submitted = true; latency.resultSubmittedToGlasses(at: now)
                }
            } catch { fail("无法编码字幕文字。") }
        } else if let target, device.deviceID == target {
            do {
                try device.sendDisplaySubtitle(target: target, payload: SubtitleDisplayWire.text(text, sid: sid))
                submitted = true
                latency.resultSubmittedToGlasses(at: now)
            } catch { dropDisplayOnly(reason: "字幕文字未能发送", notifyGlasses: true) }
        }
        if submitted, hasCompletedDisplayPair, text != " " {
            displayExpiresAt = settings.displayRetention.seconds.map { now + $0 }
        }
    }
    private func markGap(_ note: String) {
        guard !gapOpen else { return }; gapOpen = true; gaps += 1; record?.gaps = gaps
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
        pendingTranslations = 0
        #if COMPANION_DEVICE
        translator?.cancel(); translator = nil
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
        timer?.invalidate(); timer = nil; phase = .idle; target = nil; sid = nil
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
        if let displayExpiresAt, now >= displayExpiresAt { clearVisibleDisplay() }
        pumpDisplay()
    }
    private func installTimer() {
        timer?.invalidate(); timer = nil
        guard scheduleTimers else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
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
        return "Turbo IO 实时字幕\nphase=\(phase.rawValue) inputSource=\(sessionInputSource.rawValue) inputRouteType=\(inputRouteType ?? "none") displayOpening=\(displayOpening) displayReady=\(displayReady)\npackets=\(packets) pcmBytes=\(audioBytes) gaps=\(gaps)\nseqStrideChanges=\(sequenceJumps) maxSeqStep=\(maximumSequenceStep) discardedSeq=\(discardedSequencePackets)\nseqSteps=\(steps.isEmpty ? "none" : steps) otherSteps=\(otherSequenceSteps)\nmaxArrivalMs=\(maximumArrivalIntervalMilliseconds) maxDispatchMs=\(maximumDispatchDelayMilliseconds)\nASR=\(options.service.name) model=\(options.selectedModel) ready=\(cloudReady) directionRequested=\(requestedDirection.rawValue) translationEnabled=\(settings.translationEnabled) displayMode=\(effectiveDisplayMode.rawValue) retention=\(settings.displayRetention.rawValue)\n\(asrSummary)\ncontrolEvents:\n\(controls)\n不包含音频、正文、密钥、原始序号或设备标识。"
    }
}
