import Foundation
import Combine
import UIKit
import RayNeoCaptions
import RayNeoProtocol

enum AlwaysOnWire {
    static let frameBytes = 240
    static let maximumFrames = 31

    static func launcher(_ command: String, enabled: Bool) throws -> Data {
        guard ["life_log_guide", "life_log_switch"].contains(command) else { throw DeviceFeatureError.invalidPacket }
        return try DeviceBusinessWire.encode(type: 20, json: ["cmd": command,
            "payload": ["value": enabled ? 1 : 0, "mode": 0,
                        "data": command == "life_log_switch" && enabled ? "{\"delay\":2}" : ""]])
    }
    static func start(_ id: String) throws -> Data {
        guard DeviceBusinessWire.identifier(["taskId": id], "taskId") != nil else { throw DeviceFeatureError.invalidPacket }
        return try DeviceBusinessWire.encode(type: 162, json: ["taskId": id, "idleTimeoutSec": 30])
    }
    static func exit() throws -> Data { try DeviceBusinessWire.encode(type: 166, json: ["rc": 2]) }
    static func page(_ visible: Bool) throws -> Data { try DeviceBusinessWire.encode(type: 168, json: ["inRealtimePage": visible]) }

    static func frames(_ wire: DeviceBusinessWire, taskID: String) throws -> [Data] {
        guard wire.type == 163 || wire.type == 164,
              DeviceBusinessWire.identifier(wire.json, "taskId") == taskID,
              let rawCount = DeviceBusinessWire.integer(wire.json, "frameCount"),
              (1...Int64(maximumFrames)).contains(rawCount) else { throw DeviceFeatureError.invalidPacket }
        let count = Int(rawCount)
        guard wire.bytes.count == count * frameBytes else { throw DeviceFeatureError.invalidPacket }
        return (0..<count).map { index in
            Data(wire.bytes[(index * frameBytes)..<((index + 1) * frameBytes)])
        }
    }
}

private struct AlwaysOnActiveMarker: Codable {
    var runID: UUID
    var startedAt: Date
    var service: String
    var model: String
    var languageMode: RecognitionLanguageMode
}

/// Persistent app-level LifeLog runtime. Audio exists only as bounded memory on
/// the route glasses -> Opus decoder -> selected ASR provider.
@MainActor final class AlwaysOnRuntime: ObservableObject {
    enum Phase: String {
        case disabled, waitingForDevice, enablingGlasses, waitingForA1
        case transcribing, reconnectingASR, stopping, error
    }

    @Published private(set) var phase: Phase = .disabled
    @Published private(set) var status = "全天智记尚未开启"
    @Published private(set) var enabled = false
    @Published private(set) var showOnGlasses = true
    @Published private(set) var languageMode: RecognitionLanguageMode = .automatic
    @Published private(set) var partial = ""
    @Published private(set) var recent: [AlwaysOnTranscriptEntry] = []
    @Published private(set) var todaySentences = 0
    @Published private(set) var gaps = 0
    @Published private(set) var packets = 0
    @Published private(set) var cachedPackets = 0
    @Published private(set) var cloudReady = false
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var legacyDiagnosticsAvailable = false
    @Published private(set) var legacyDeletionStatus: String?
    @Published private(set) var error: String?
    @Published private(set) var events: [String] = []

    let archive: AlwaysOnTranscriptArchive
    let settings: SubtitleSettingsStore
    private let defaults: UserDefaults
    private let device: () -> String?
    private let supportsDevice: () -> Bool
    private let available: () -> Bool
    private let suspendVoice: () -> Void
    private let claimDisplay: (Bool) -> Void
    private let sendBusiness: (UInt8, Data) throws -> Void
    private let makeDecoder: () -> SubtitlePCMDecoder?
    private let uptime: () -> TimeInterval
    private let dateNow: () -> Date
    private let scheduleTimers: Bool
    private let legacyDiagnosticsRoot: URL
    private let presenter: LensCaptionPresenter
    private var preferences: AlwaysOnSettings
    private var provider: CaptionASRProvider?
    private var decoder: SubtitlePCMDecoder?
    private var optionsSnapshot: CaptionOptions?
    private var keySnapshot = ""
    private var target: String?
    private var taskID: String?
    private var runID: UUID?
    private var runStartedAt: Date?
    private var lastDayCheckAt: Date?
    private var archivedDay: String?
    private var generation = UUID()
    private var retryBudget = CaptionRetryBudget()
    private var retryTask: Task<Void, Never>?
    private var reconnectBuffer: [Data] = []
    private var reconnectBytes = 0
    private var reconnectGapOpen = false
    private var cachedGapRecorded = false
    private var timer: Timer?
    private var lifecycle: [NSObjectProtocol] = []
    private static let settingsKey = "companion.alwaysOn.settings.v1"
    private static let activeMarkerKey = "companion.alwaysOn.activeRun.v1"

    var occupied: Bool { enabled || ![.disabled, .waitingForDevice].contains(phase) }
    var activeTask: Bool { taskID != nil }
    var canEnable: Bool { supportsDevice() && device() != nil }
    var serviceSummary: String {
        let options = optionsSnapshot ?? settings.options
        return "\(options.service.name) · \(options.selectedModel)"
    }
    var languageSummary: String {
        switch languageMode {
        case .automatic: return "自动检测"
        case .fixed(let value): return value
        }
    }

    init(defaults: UserDefaults = .standard, archive: AlwaysOnTranscriptArchive,
         settings: SubtitleSettingsStore,
         device: @escaping () -> String?, supportsDevice: @escaping () -> Bool,
         available: @escaping () -> Bool, suspendVoice: @escaping () -> Void,
         claimDisplay: @escaping (Bool) -> Void,
         sendBusiness: @escaping (UInt8, Data) throws -> Void,
         sendSubtitle: @escaping (String, Data) throws -> Void,
         makeDecoder: (() -> SubtitlePCMDecoder?)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         dateNow: @escaping () -> Date = { Date() },
         scheduleTimers: Bool = true, legacyDiagnosticsRoot: URL? = nil) {
        self.defaults = defaults; self.archive = archive; self.settings = settings
        self.device = device; self.supportsDevice = supportsDevice; self.available = available
        self.suspendVoice = suspendVoice; self.claimDisplay = claimDisplay
        self.sendBusiness = sendBusiness; self.uptime = uptime; self.dateNow = dateNow
        self.scheduleTimers = scheduleTimers
        self.legacyDiagnosticsRoot = legacyDiagnosticsRoot
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AlwaysOnLocalProbeV1", isDirectory: true)
        self.makeDecoder = makeDecoder ?? {
            #if COMPANION_DEVICE
            return NativeSubtitlePCMDecoder()
            #else
            return nil
            #endif
        }
        if let data = defaults.data(forKey: Self.settingsKey),
           let restored = try? JSONDecoder().decode(AlwaysOnSettings.self, from: data) {
            preferences = restored
        } else { preferences = AlwaysOnSettings() }
        presenter = LensCaptionPresenter(currentDevice: device, claimDisplay: claimDisplay,
            send: sendSubtitle, uptime: uptime)
        enabled = preferences.enabled; showOnGlasses = preferences.showOnGlasses
        languageMode = preferences.languageMode
        phase = enabled ? .waitingForDevice : .disabled
        status = enabled ? "已记住全天智记，等待同一副眼镜连接" : "全天智记尚未开启"
        presenter.onFailure = { [weak self] message in self?.note(message); self?.error = message }
        refreshLegacyDiagnostics()
        recoverInterruptedRun()
        if scheduleTimers {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            for name in [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification] {
                lifecycle.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.connectionChanged() }
                })
            }
        }
    }

    deinit {
        timer?.invalidate(); retryTask?.cancel()
        for observer in lifecycle { NotificationCenter.default.removeObserver(observer) }
    }

    func prepare() {
        settings.refresh()
        refreshLegacyDiagnostics()
        Task { [weak self] in
            guard let self else { return }
            await self.archive.load()
            self.restoreTodayCounters()
        }
        connectionChanged()
    }

    func deleteLegacyDiagnostics() {
        do {
            let info = try legacyDiagnosticsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                legacyDeletionStatus = "旧诊断目录格式异常，未删除。"
                return
            }
            try FileManager.default.removeItem(at: legacyDiagnosticsRoot)
            legacyDiagnosticsAvailable = false
            legacyDeletionStatus = "旧诊断数据已删除，无法恢复。"
        } catch {
            refreshLegacyDiagnostics()
            legacyDeletionStatus = legacyDiagnosticsAvailable ? "旧诊断数据删除失败，原文件仍保留。" : "没有找到旧诊断数据。"
        }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { if value { startIfPossible() }; return }
        if value {
            guard supportsDevice(), let current = device() else {
                error = "请先连接并认证要用于全天智记的眼镜。"; return
            }
            var requested = settings.options
            requested.languageMode = languageMode; requested.recordAudio = false; requested.idleSeconds = 0
            guard settings.recognizer(for: requested) != nil else {
                error = requested.service == .deepgram && languageMode == .automatic
                    ? "Deepgram Nova-3 的全天智记需要先选择固定语言。"
                    : "请先保存当前 ASR 服务的有效配置与 API Key。"
                return
            }
            preferences.enabled = true; preferences.targetDeviceID = current
            enabled = true; persistPreferences(); error = nil
            startIfPossible()
        } else {
            preferences.enabled = false; enabled = false; persistPreferences()
            stopEverything(reason: "用户关闭全天智记", sendOff: true)
            phase = .disabled; status = "全天智记已关闭"
        }
    }

    func setShowOnGlasses(_ value: Bool) {
        showOnGlasses = value; preferences.showOnGlasses = value; persistPreferences()
        guard activeTask, let target else { return }
        if value { _ = presenter.open(on: target); refreshLens(final: true) }
        else { presenter.close(notifyGlasses: true) }
    }

    @discardableResult func setLanguage(_ mode: RecognitionLanguageMode, policy: AlwaysOnApplyPolicy) -> Bool {
        guard policy != .cancel else { return false }
        var candidate = settings.options; candidate.languageMode = mode; candidate.recordAudio = false
        do { _ = try candidate.validated() }
        catch {
            self.error = candidate.service == .deepgram && mode == .automatic
                ? "Deepgram Nova-3 当前需要选择固定语言；不会自动切换服务。"
                : "当前服务不支持这个语言设置。"
            return false
        }
        languageMode = mode; preferences.languageMode = mode; persistPreferences(); self.error = nil
        if activeTask, policy == .immediately {
            optionsSnapshot = candidate
            restartASR(reason: "语言设置立即生效，ASR 已重新连接")
        } else if activeTask {
            status = "语言设置已保存，将在下一次眼镜语音任务生效"
        }
        return true
    }

    @discardableResult func applySpeechSettings(_ draft: CaptionOptions, key: String,
                                                 policy: AlwaysOnApplyPolicy) -> Bool {
        guard policy != .cancel else { return false }
        var candidate = draft; candidate.languageMode = languageMode; candidate.recordAudio = false
        do { _ = try candidate.validated() }
        catch {
            self.error = candidate.service == .deepgram && languageMode == .automatic
                ? "Deepgram 与自动检测不能组合；请选择固定语言。" : "转写设置不完整。"
            return false
        }
        guard settings.save(draft, key: key, allowActiveAlwaysOn: true) else { return false }
        if activeTask, policy == .immediately {
            optionsSnapshot = candidate
            restartASR(reason: "服务设置立即生效，ASR 已重新连接")
        } else if activeTask {
            status = "转写服务设置已保存，将在下一次眼镜语音任务生效"
        }
        return true
    }

    func connectionChanged() {
        guard enabled else { return }
        guard let expected = preferences.targetDeviceID, let current = device(), expected == current else {
            if activeTask {
                guard appendRequired(kind: .gap, text: "眼镜连接中断，当前语音任务已结束") else { return }
                gaps += 1
                finishTask(reason: "眼镜连接中断", next: .waitingForDevice, notifyLens: false)
            }
            phase = .waitingForDevice; status = device() == nil ? "等待已绑定眼镜重新连接" : "连接的不是已启用全天智记的眼镜"
            return
        }
        startIfPossible()
    }

    func receive(device source: String, business: UInt8, packet: Data) {
        guard enabled, source == device(), source == preferences.targetDeviceID else { return }
        if business == SubtitleDisplayWire.business {
            presenter.receive(device: source, packet: packet)
            if let event = try? SubtitleTranslateWire.event(packet), event.type == 1 {
                note("收到普通字幕 type=1；全天智记占用，未启动另一条收音链")
            }
            return
        }
        do {
            let wire = try DeviceBusinessWire(packet)
            if business == 15 { handleLauncher(wire); return }
            guard business == 13, (161...168).contains(wire.type) else { return }
            switch wire.type {
            case 161: try beginTask(source: source)
            case 163: try acceptRealtimeBatch(wire)
            case 164: try acceptCachedBatch(wire)
            case 165:
                note("收到 A5，眼镜结束当前全天语音任务")
                finishTask(reason: "眼镜结束当前语音任务", next: .waitingForA1, notifyLens: true)
            default: break
            }
        } catch is AlwaysOnArchiveError {
            storageFailed()
        } catch {
            failTask("全天协议包、taskId、帧数量或 Opus 音频格式不匹配，已安全停止当前任务。")
        }
    }

    func lostMessages() {
        guard activeTask else { return }
        guard appendRequired(kind: .gap, text: "手机业务接收队列丢包，缺失部分未补录") else { return }
        gaps += 1
        decoder?.reset(); reconnectBuffer.removeAll(); reconnectBytes = 0
    }

    func displayTransportFailed(device: String, packet: Data, code: Int) {
        presenter.transportFailed(device: device, packet: packet, code: code)
    }

    func tick() {
        presenter.tick()
        guard enabled else { return }
        if device() != preferences.targetDeviceID { connectionChanged(); return }
        if phase == .waitingForDevice { startIfPossible() }
        guard activeTask else { return }
        let nowDate = dateNow()
        let day = archive.dayKey(for: nowDate)
        if let archivedDay, archivedDay != day {
            if !partial.isEmpty {
                guard appendRequired(kind: .unfinished, text: partial,
                                     timestamp: lastDayCheckAt ?? runStartedAt ?? nowDate,
                                     day: archivedDay) else { return }
                partial = ""
            }
            self.archivedDay = day; todaySentences = 0
            gaps = 0
            guard appendRequired(kind: .system, text: "本地自然日已切换") else { return }
        }
        lastDayCheckAt = nowDate
    }

    private func startIfPossible() {
        guard enabled, (phase == .waitingForDevice || phase == .disabled), !activeTask,
              let expected = preferences.targetDeviceID, device() == expected else { return }
        guard available() else { phase = .waitingForDevice; status = "等待其他眼镜任务结束后恢复全天智记"; return }
        suspendVoice(); phase = .enablingGlasses; target = expected; error = nil
        do {
            try sendBusiness(15, AlwaysOnWire.launcher("life_log_guide", enabled: true))
            try sendBusiness(15, AlwaysOnWire.launcher("life_log_switch", enabled: true))
            phase = .waitingForA1; status = "全天智记已开启，等待眼镜实时音频"
            note("已发送 life_log_guide/switch ON")
        } catch {
            phase = .waitingForDevice; self.error = "全天智记开启命令未能送达眼镜，将在连接恢复后重试。"
        }
    }

    private func beginTask(source: String) throws {
        guard phase == .waitingForA1 || phase == .enablingGlasses, !activeTask else { return }
        var requested = settings.options
        requested.languageMode = languageMode; requested.recordAudio = false; requested.idleSeconds = 0
        guard let config = settings.recognizer(for: requested) else {
            phase = .error
            error = requested.service == .deepgram && languageMode == .automatic
                ? "Deepgram Nova-3 的全天智记需要固定语言。请选择中文、英国英语或美国英语。"
                : "请先配置当前 ASR 服务和它自己的 API Key。"
            try? sendBusiness(13, AlwaysOnWire.exit()); try? sendBusiness(13, AlwaysOnWire.page(false))
            return
        }
        guard let decoder = makeDecoder() else { throw DeviceFeatureError.invalidPacket }
        let run = UUID(), task = UUID().uuidString
        optionsSnapshot = config.options; keySnapshot = config.key; provider = config.provider
        detectedLanguage = config.options.cloudLanguage
        self.decoder = decoder; runID = run; taskID = task; runStartedAt = dateNow()
        lastDayCheckAt = runStartedAt
        archivedDay = archive.dayKey(for: runStartedAt!); target = source
        partial = ""; recent = []; packets = 0; cachedPackets = 0
        cachedGapRecorded = false; reconnectGapOpen = false; reconnectBuffer = []; reconnectBytes = 0
        retryBudget = CaptionRetryBudget(); generation = UUID(); cloudReady = false
        guard appendRequired(kind: .started,
              text: "\(config.options.service.name) · \(config.options.selectedModel) · \(config.options.languageName)") else { return }
        persistActiveMarker(runID: run, options: config.options)
        bindAndStartProvider(config.provider, options: config.options, key: config.key)
        let token = generation
        guard generation == token, activeTask else { return }
        try sendBusiness(13, AlwaysOnWire.start(task))
        try sendBusiness(13, AlwaysOnWire.page(true))
        phase = .transcribing; status = "已接收眼镜任务，正在连接转写服务"
        if showOnGlasses { _ = presenter.open(on: source) }
        note("A1 → A2，已发送 A8 inRealtimePage=true")
    }

    private func acceptRealtimeBatch(_ wire: DeviceBusinessWire) throws {
        guard let taskID, activeTask, phase == .transcribing || phase == .reconnectingASR else { return }
        let frames = try AlwaysOnWire.frames(wire, taskID: taskID)
        for frame in frames {
            guard let pcm = decoder?.decode(frame), pcm.count == 640 else { throw DeviceFeatureError.invalidPacket }
            if cloudReady, phase == .transcribing { provider?.append(pcm) }
            else { bufferDuringReconnect(pcm) }
        }
        packets += 1
    }

    private func acceptCachedBatch(_ wire: DeviceBusinessWire) throws {
        guard let taskID, activeTask else { return }
        _ = try AlwaysOnWire.frames(wire, taskID: taskID)
        cachedPackets += 1
        if !cachedGapRecorded {
            cachedGapRecorded = true
            guard appendRequired(kind: .gap,
                  text: "收到眼镜缓存音频；因顺序与去重语义尚未验证，本版未上传转写") else { return }
            gaps += 1
        }
    }

    private func bindAndStartProvider(_ provider: CaptionASRProvider, options: CaptionOptions, key: String) {
        let token = generation
        provider.onReady = { [weak self] in
            guard let self, self.generation == token, self.activeTask else { return }
            self.cloudReady = true; self.phase = .transcribing
            self.status = "全天智记正在转写 · \(options.service.name)"
            let buffered = self.reconnectBuffer
            self.reconnectBuffer.removeAll(); self.reconnectBytes = 0
            for pcm in buffered { provider.append(pcm) }
            if self.reconnectGapOpen {
                guard self.appendRequired(kind: .gap,
                      text: "ASR 已恢复；重连期间超出内存缓冲的音频未补录") else { return }
                self.gaps += 1
                self.reconnectGapOpen = false
            }
        }
        provider.onText = { [weak self] text, final in
            guard let self, self.generation == token else { return }
            self.recognized(text, final: final)
        }
        provider.onEndpoint = nil
        provider.onFailure = { [weak self] failure in
            guard let self, self.generation == token else { return }
            self.cloudFailed(failure)
        }
        provider.start(options: options, key: key)
    }

    private func recognized(_ text: String, final: Bool) {
        guard activeTask, text.utf8.count <= 32_768 else {
            if text.utf8.count > 32_768 { failTask("ASR 返回单句超过保存上限。") }
            return
        }
        cloudReady = true; partial = text
        if final {
            retryBudget.recognized()
            if !text.isEmpty {
                do {
                    try append(kind: .final, text: text)
                    let entry = AlwaysOnTranscriptEntry(timestamp: dateNow(), runID: runID!, kind: .final, text: text,
                        service: optionsSnapshot?.service.name ?? "", model: optionsSnapshot?.selectedModel ?? "",
                        languageMode: optionsSnapshot?.languageMode ?? languageMode,
                        detectedLanguage: detectedLanguage)
                    recent.append(entry); recent = Array(recent.suffix(100))
                    todaySentences += 1
                } catch { storageFailed() ; return }
            }
            partial = ""
        }
        refreshLens(final: final, provisional: text)
    }

    private func refreshLens(final: Bool, provisional: String? = nil) {
        guard showOnGlasses else { return }
        let tail = recent.suffix(2).map(\.text).joined(separator: "\n")
        let visible = final ? tail : [tail, provisional ?? partial].filter { !$0.isEmpty }.joined(separator: "\n")
        presenter.update(visible.isEmpty ? "全天智记正在聆听…" : visible, final: final)
    }

    private func cloudFailed(_ failure: CaptionConnectionFailure) {
        cloudReady = false
        guard failure.canRetry, let delay = retryBudget.nextDelay() else {
            failTask("\(optionsSnapshot?.service.name ?? "ASR")：\(failure.message)")
            return
        }
        provider?.stop(); provider = nil; phase = .reconnectingASR
        status = "ASR 连接中断，\(Int(delay)) 秒后重试；眼镜采音保持不变"
        guard appendRequired(kind: .system,
              text: "ASR 连接中断，开始第 \(retryBudget.attempts) 次重连") else { return }
        let token = generation
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self else { return }
            guard self.generation == token, self.activeTask,
                  let options = self.optionsSnapshot,
                  let config = self.settings.recognizer(for: options) else {
                self.failTask("ASR 重连配置或密钥不可用。")
                return
            }
            self.provider = config.provider; self.keySnapshot = config.key
            self.bindAndStartProvider(config.provider, options: options, key: config.key)
        }
    }

    private func bufferDuringReconnect(_ pcm: Data) {
        guard reconnectBytes + pcm.count <= 64_000 else { reconnectGapOpen = true; return }
        reconnectBuffer.append(pcm); reconnectBytes += pcm.count
    }

    private func restartASR(reason: String) {
        guard activeTask, var options = optionsSnapshot else { return }
        options.languageMode = languageMode; options.recordAudio = false
        guard let config = settings.recognizer(for: options) else {
            failTask("新 ASR 设置缺少有效配置或密钥，当前任务已停止。")
            return
        }
        guard appendRequired(kind: .system, text: reason) else { return }
        generation = UUID(); retryTask?.cancel(); provider?.stop(); cloudReady = false
        reconnectBuffer.removeAll(); reconnectBytes = 0; reconnectGapOpen = false
        retryBudget = CaptionRetryBudget(); optionsSnapshot = config.options; keySnapshot = config.key
        detectedLanguage = config.options.cloudLanguage
        provider = config.provider; phase = .reconnectingASR; status = "正在按新设置重启 ASR；眼镜采音保持不变"
        bindAndStartProvider(config.provider, options: config.options, key: config.key)
    }

    private func failTask(_ message: String) {
        error = message
        if activeTask {
            guard appendRequired(kind: .gap, text: message) else { return }
            gaps += 1
        }
        try? sendBusiness(13, AlwaysOnWire.exit()); try? sendBusiness(13, AlwaysOnWire.page(false))
        finishTask(reason: message, next: .error, notifyLens: true)
        status = message
    }

    private func finishTask(reason: String, next: Phase, notifyLens: Bool) {
        guard activeTask else { phase = next; return }
        generation = UUID(); retryTask?.cancel(); retryTask = nil
        provider?.stop(); provider = nil; cloudReady = false
        var storageSucceeded = true
        if !partial.isEmpty {
            do { try append(kind: .unfinished, text: partial) }
            catch { storageSucceeded = false }
            partial = ""
        }
        do { try append(kind: .stopped, text: reason) }
        catch { storageSucceeded = false }
        presenter.close(notifyGlasses: notifyLens)
        decoder = nil; taskID = nil; runID = nil; runStartedAt = nil; lastDayCheckAt = nil
        optionsSnapshot = nil; keySnapshot = ""; detectedLanguage = nil
        reconnectBuffer.removeAll(); reconnectBytes = 0
        defaults.removeObject(forKey: Self.activeMarkerKey)
        if storageSucceeded {
            phase = next
            if next == .waitingForA1 { status = "本轮已保存，继续等待下一次眼镜语音任务" }
        } else {
            preferences.enabled = false; enabled = false; persistPreferences()
            try? sendBusiness(15, AlwaysOnWire.launcher("life_log_switch", enabled: false))
            try? sendBusiness(15, AlwaysOnWire.launcher("life_log_guide", enabled: false))
            try? sendBusiness(13, AlwaysOnWire.page(false))
            phase = .error
            error = "全天智记文字存储失败，已立即停止；最后一段可能不完整。"
            status = error!
        }
        Task { await archive.load() }
    }

    private func stopEverything(reason: String, sendOff: Bool) {
        phase = .stopping
        if activeTask { try? sendBusiness(13, AlwaysOnWire.exit()) }
        if sendOff {
            try? sendBusiness(15, AlwaysOnWire.launcher("life_log_switch", enabled: false))
            try? sendBusiness(15, AlwaysOnWire.launcher("life_log_guide", enabled: false))
            try? sendBusiness(13, AlwaysOnWire.page(false))
        }
        finishTask(reason: reason, next: .disabled, notifyLens: true)
        presenter.close(notifyGlasses: true); target = nil
    }

    private func storageFailed() {
        guard phase != .stopping else { return }
        error = "全天智记文字存储失败，已立即停止；不会继续显示为已保存。"
        preferences.enabled = false; enabled = false; persistPreferences()
        stopEverything(reason: "文字存储失败", sendOff: true)
        phase = .error; status = error!
    }

    private func handleLauncher(_ wire: DeviceBusinessWire) {
        guard let command = wire.json["cmd"] as? String, command.hasPrefix("life_log_"),
              let payload = wire.json["payload"] as? [String: Any] else { return }
        let value = DeviceBusinessWire.integer(payload, "value")
        note("\(command) value=\(value.map(String.init) ?? "缺省")")
        if command == "life_log_switch_result", let value, value != 0 {
            error = [1: "眼镜没有麦克风权限", 2: "请展开镜腿", 3: "眼镜电量过低"][Int(value)]
                ?? "眼镜拒绝全天智记，结果码 \(value)"
            phase = .error
        }
    }

    private func append(kind: AlwaysOnTranscriptKind, text: String, timestamp: Date? = nil,
                        day: String? = nil) throws {
        guard let runID, let options = optionsSnapshot else { throw AlwaysOnArchiveError.invalidEntry }
        try archive.append(AlwaysOnTranscriptEntry(timestamp: timestamp ?? dateNow(), runID: runID, kind: kind, text: text,
            service: options.service.name, model: options.selectedModel,
            languageMode: options.languageMode, detectedLanguage: detectedLanguage ?? options.cloudLanguage), to: day)
    }

    @discardableResult private func appendRequired(kind: AlwaysOnTranscriptKind, text: String,
                                                   timestamp: Date? = nil, day: String? = nil) -> Bool {
        do { try append(kind: kind, text: text, timestamp: timestamp, day: day); return true }
        catch { storageFailed(); return false }
    }

    private func persistPreferences() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.settingsKey) }
    }

    private func persistActiveMarker(runID: UUID, options: CaptionOptions) {
        let marker = AlwaysOnActiveMarker(runID: runID, startedAt: dateNow(), service: options.service.name,
            model: options.selectedModel, languageMode: options.languageMode)
        if let data = try? JSONEncoder().encode(marker) { defaults.set(data, forKey: Self.activeMarkerKey) }
    }

    private func recoverInterruptedRun() {
        guard let data = defaults.data(forKey: Self.activeMarkerKey),
              let marker = try? JSONDecoder().decode(AlwaysOnActiveMarker.self, from: data) else { return }
        let entry = AlwaysOnTranscriptEntry(timestamp: dateNow(), runID: marker.runID, kind: .gap,
            text: "App 上次运行被中断，期间可能缺失", service: marker.service, model: marker.model,
            languageMode: marker.languageMode, detectedLanguage: nil)
        do { try archive.append(entry); defaults.removeObject(forKey: Self.activeMarkerKey) }
        catch {
            preferences.enabled = false; enabled = false; persistPreferences()
            phase = .error; status = "全天智记因本机文字存储不可用而暂停"
            self.error = "无法写入上次 App 中断记录；已停止自动恢复，请检查本机存储。"
        }
    }

    private func restoreTodayCounters() {
        let today = archive.dayKey(for: dateNow())
        guard !activeTask else { return }
        let summary = archive.days.first { $0.day == today }
        todaySentences = summary?.finalCount ?? 0
        gaps = summary?.gapCount ?? 0
    }

    private func refreshLegacyDiagnostics() {
        guard FileManager.default.fileExists(atPath: legacyDiagnosticsRoot.path),
              let info = try? legacyDiagnosticsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            legacyDiagnosticsAvailable = false
            return
        }
        legacyDiagnosticsAvailable = info.isDirectory == true && info.isSymbolicLink != true
    }

    private func note(_ text: String) {
        events.append("\(dateNow().formatted(date: .omitted, time: .standard)) \(text)")
        events = Array(events.suffix(100))
    }

    var diagnosticText: String {
        let controls = events.isEmpty ? "none" : events.joined(separator: "\n")
        return "Turbo IO 全天智记\nphase=\(phase.rawValue) enabled=\(enabled) packets=\(packets) cachedPackets=\(cachedPackets) gaps=\(gaps)\nASR=\(serviceSummary) ready=\(cloudReady) language=\(languageSummary)\n\(status)\n\(error ?? "")\ncontrolEvents:\n\(controls)\n不包含音频、字幕正文、密钥、设备标识或原始业务包。"
    }
}
