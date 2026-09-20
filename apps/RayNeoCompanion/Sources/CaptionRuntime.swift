import SwiftUI
import UIKit
import RayNeoCaptions
import RayNeoProtocol

/// A deliberately separate owner of business 13: no LLM, TTS or assistant reply timer.
/// A user must arm each session AND wake the glasses. Neither reconnect nor launch arms it.
@MainActor final class CaptionRuntime: ObservableObject {
    enum Phase: String { case idle, preparing, armed, listening, reconnecting, stopping }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "尚未开启字幕"
    @Published private(set) var partial = ""
    @Published private(set) var recent: [CaptionEntry] = []
    @Published private(set) var elapsed = 0
    @Published private(set) var options: CaptionOptions
    @Published var error: String?
    let root: URL
    let voice: CompanionVoiceRuntime
    private let defaults: UserDefaults
    private static let settingsKey = "companion.azureCaptions.options.v1"
    private var provider: CaptionASRProvider?
    private var sink: CaptionDiskSink?
    private var generation = UUID(), diskGeneration = UUID(), target: String?, key = ""
    private var clock: CaptionClock?, activity = CaptionVoiceActivity()
    private var retry = CaptionRetryBudget(), retryAt: TimeInterval?, cloudDeadline: TimeInterval?
    private var timer: Timer?, lifecycle: NSObjectProtocol?
    private var armedAt: TimeInterval = 0, lastAudio: TimeInterval?
    private var lastDisplay: TimeInterval = 0, dirtyDisplay = false, newSentence = true
    private var gapOpen = false
    private var unansweredSpeechAt: TimeInterval?
    private var flushTask: UIBackgroundTaskIdentifier = .invalid
    #if COMPANION_DEVICE
    private var decoder: OpaquePointer?
    #endif
    var active: Bool { phase != .idle }
    var supportsDevice: Bool { voice.supportsDevice }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(voice: CompanionVoiceRuntime, defaults: UserDefaults = .standard, root: URL? = nil) {
        self.voice = voice; self.defaults = defaults
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AzureCaptionsV1", isDirectory: true)
        var saved = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(CaptionOptions.self, from: $0) }
            ?? CaptionOptions()
        saved.recordAudio = false // Consent to retain audio is per session, never remembered.
        options = saved
        #if COMPANION_DEVICE
        provider = AzureCaptionASR()
        #endif
        voice.onCaptionEnvelope = { [weak self] in self?.receive(device: $0, type: $1, audio: $2, arrival: $3) }
        voice.onCaptionInputLoss = { [weak self] device in
            guard let self, self.target == device, self.clock != nil else { return }
            self.markInputGap()
        }
        lifecycle = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    deinit {
        timer?.invalidate()
        if let lifecycle { NotificationCenter.default.removeObserver(lifecycle) }
    }
    func hasKey(region: String) -> Bool {
        AzureCaptionCredentials.read(region: region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) != nil
    }
    @discardableResult func save(_ draft: CaptionOptions, newKey: String) -> Bool {
        guard !active, supportsDevice else { error = "请在真机中结束字幕后设置。"; return false }
        do {
            var value = try draft.validated()
            if !newKey.isEmpty { try AzureCaptionCredentials.save(newKey, region: value.region) }
            value.recordAudio = false
            defaults.set(try JSONEncoder().encode(value), forKey: Self.settingsKey); options = value
            error = nil; return true
        } catch { self.error = "设置未保存。请检查 Region、语言、时长和密钥格式。"; return false }
    }
    func forgetKey(region: String) {
        guard !active else { return }
        do { try AzureCaptionCredentials.remove(region: region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        catch { self.error = "无法移除此区域的密钥。" }
    }
    func arm(_ draft: CaptionOptions) {
        guard !active else { return }
        voice.prepare()
        guard supportsDevice, let provider, let device = voice.deviceID,
              voice.featureIsBusy?() != true else { error = "需要唯一已认证的眼镜，并结束录音、提词器等占用任务。"; return }
        guard let value = try? draft.validated(), let secret = AzureCaptionCredentials.read(region: value.region),
              !secret.isEmpty else { error = "请先保存有效设置和此 Region 对应的 Azure Speech Key。"; return }
        error = nil; options = value; key = secret; target = device; phase = .preparing
        recent = []; partial = ""; elapsed = 0; retry = CaptionRetryBudget()
        generation = UUID(); diskGeneration = generation; let token = generation, root = root
        voice.ownVoiceForCaptions(true)
        status = "正在准备本地字幕记录"
        // Provider callbacks also gate on session generation, not just SDK instance identity.
        provider.onText = { [weak self] text, final in
            guard let self, self.generation == token else { return }; self.recognized(text, final: final)
        }
        provider.onReady = { [weak self] in
            guard let self, self.generation == token, self.clock != nil,
                  self.phase == .listening else { return }
            self.cloudDeadline = nil; self.status = "Azure 已连接 · 正在接收眼镜音频"
        }
        provider.onFailure = { [weak self] in
            guard let self, self.generation == token else { return }; self.cloudFailed()
        }
        Task {
            do {
                let output = try await Task.detached(priority: .utility) { [weak self] in
                    try CaptionDiskSink(root: root, id: token, recordAudio: value.recordAudio) {
                        Task { @MainActor [weak self] in
                            guard let self, self.diskGeneration == token else { return }
                            self.error = "本地存储失败或写入跟不上；本次历史/录音可能不完整。"
                            self.stop(reason: "本地存储失败")
                        }
                    }
                }.value
                guard generation == token, phase == .preparing else {
                    output.event(CaptionEntry(kind: .stopped, text: "准备阶段已取消，未开启采音"))
                    output.close {}; return
                }
                sink = output
                guard voice.deviceID == device else { stop(reason: "准备时眼镜已断开"); return }
                phase = .armed; armedAt = now
                status = "字幕已待命：请主动唤醒眼镜（5 分钟内）"
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            } catch {
                guard generation == token else { return }
                self.error = "无法创建字幕记录：请检查存储空间，或删除不需要的字幕历史（上限 100 次）。"
                stop(reason: "本地存储未就绪")
            }
        }
    }
    private func receive(device: String, type: UInt32, audio: Data?, arrival: TimeInterval) {
        guard target == device, voice.deviceID == device, active, phase != .stopping else { return }
        guard arrival <= now, now - arrival <= 0.5 else {
            if type == 3, clock != nil { markInputGap() }; return
        }
        if type == 8 { stop(reason: "眼镜主动结束会话"); return }
        if type == 1, phase == .armed {
            #if COMPANION_DEVICE
            guard let handle = RNVoiceVADCreate() else { stop(reason: "无法创建音频解码器"); return }
            decoder = handle
            #else
            return
            #endif
            clock = CaptionClock(options: options, now: now); activity = CaptionVoiceActivity()
            lastAudio = nil; gapOpen = false; newSentence = true; lastDisplay = 0
            phase = .listening
            sink?.event(CaptionEntry(kind: .started,
                text: "Azure \(options.region) / \(options.language); 静音退出 \(options.idleSeconds)s; 上限 \(options.maximumSeconds)s; 保存音频 \(options.recordAudio)"))
            guard send(AssistantRecorderPrototype.control(start: true)) else { return }
            startCloud(); return
        }
        guard type == 3, let startedAt = clock?.startedAt, arrival >= startedAt else { return }
        guard let audio, !audio.isEmpty, audio.count <= 4_096 else { markInputGap(); return }
        if let lastAudio {
            guard arrival > lastAudio else { return }
            if arrival - lastAudio > 0.2 { markInputGap() }
        }
        self.lastAudio = arrival
        #if COMPANION_DEVICE
        guard let decoder else { return }
        var samples = [Int16](repeating: 0, count: 1_920), mask: UInt32 = 0
        let frames = audio.withUnsafeBytes { bytes in
            samples.withUnsafeMutableBufferPointer { buffer in
                RNVoiceVADProcessPCM(decoder, bytes.bindMemory(to: UInt8.self).baseAddress,
                                     bytes.count, &mask, buffer.baseAddress, buffer.count)
            }
        }
        guard frames > 0, frames <= 12 else { markInputGap(); return }
        clock?.audio(now: arrival)
        for frame in 0..<Int(frames) where activity.accept(mask & (UInt32(1) << frame) != 0) {
            clock?.speech(now: arrival)
            if unansweredSpeechAt == nil, phase == .listening { unansweredSpeechAt = now }
        }
        let pcm = samples.withUnsafeBytes { Data($0.prefix(Int(frames) * 160 * 2)) }
        if gapOpen { sink?.event(CaptionEntry(kind: .gap, text: "眼镜音频恢复；缺失部分未补录")); gapOpen = false }
        sink?.pcm(pcm)
        if phase == .listening { provider?.append(pcm) }
        #endif
        tick()
    }
    private func startCloud() {
        phase = .listening; retryAt = nil; cloudDeadline = now + 15; unansweredSpeechAt = nil
        status = "正在连接 Azure；音频仅发送到你配置的 Speech 资源"
        provider?.start(options: options, key: key)
    }
    private func cloudFailed() {
        guard clock != nil, phase == .listening else { return }
        provider?.stop(); cloudDeadline = nil
        preservePartial(); dirtyDisplay = false; newSentence = true
        guard let delay = retry.nextDelay() else { stop(reason: "Azure 重连 3 次仍未恢复，请检查网络、区域、密钥和额度"); return }
        phase = .reconnecting; retryAt = now + delay
        status = "Azure 连接中断 · 重试 \(retry.attempts)/3；这段音频不会补传"
        sink?.event(CaptionEntry(kind: .gap, text: status))
    }
    private func recognized(_ text: String, final: Bool) {
        guard phase == .listening, clock != nil else { return }
        unansweredSpeechAt = nil
        guard text.utf8.count <= 32_768 else { stop(reason: "Azure 返回的单句超过保存上限"); return }
        if !text.isEmpty { retry.recognized(); cloudDeadline = nil }
        partial = text; dirtyDisplay = true
        if final {
            // NoMatch is not a final transcript and must not promote an old partial.
            if !text.isEmpty {
                let entry = CaptionEntry(kind: .final, text: text)
                recent.append(entry); if recent.count > 200 { recent.removeFirst(recent.count - 200) }
                sink?.event(entry)
            }
            display(final: true); partial = ""; newSentence = true
        } else if now - lastDisplay >= 0.25 { display(final: false) }
    }
    private func display(final: Bool) {
        guard dirtyDisplay else { return }; dirtyDisplay = false
        if newSentence {
            guard send(AssistantVADPrototype.status(.start)) else { return }; newSentence = false
        }
        guard let payload = try? AssistantTextPrototype.asrText(CaptionText.lensWindow(partial), isFinal: final) else { return }
        _ = send(payload); lastDisplay = now
        // No responseComplete or TTS. Firmware owns layout; submission is not rendering ACK.
    }
    private func markInputGap() {
        guard !gapOpen else { return }; gapOpen = true
        activity = CaptionVoiceActivity(); sink?.gap()
        sink?.event(CaptionEntry(kind: .gap, text: "眼镜音频缺口/解码失败；不补静音、不伪造连续录音"))
        #if COMPANION_DEVICE
        if let decoder { _ = RNVoiceVADReset(decoder) }
        #endif
    }
    private func tick() {
        guard phase == .armed || phase == .listening || phase == .reconnecting else { return }
        guard voice.deviceID == target else { stop(reason: "眼镜连接中断；不会自动重新采音，请检查眼镜录音指示"); return }
        if phase == .armed {
            if now - armedAt >= 300 { stop(reason: "5 分钟未唤醒，字幕待命已退出") }; return
        }
        guard let clock else { return }
        elapsed = max(0, Int(now - clock.startedAt))
        switch clock.decision(now: now) {
        case .stopLimit: stop(reason: "达到本次字幕时长上限"); return
        case .stopIdle: stop(reason: "达到设置的无人声退出时间"); return
        case .stopMissingAudio: stop(reason: "15 秒未收到有效眼镜音频，已停止（不是静音）"); return
        case .audioGap: markInputGap(); status = "等待眼镜音频恢复，未收到音频不视为静音"
        case .keepListening: break
        }
        if let deadline = cloudDeadline, now >= deadline { cloudFailed() }
        if let speech = unansweredSpeechAt, now - speech >= 30 { cloudFailed() }
        if let retryAt, now >= retryAt { startCloud() }
        if dirtyDisplay, now - lastDisplay >= 0.25 { display(final: false) }
    }
    private func send(_ payload: Data) -> Bool {
        guard let target else { return false }
        do { try voice.sendCaption(target: target, payload: payload); return true }
        catch { stop(reason: "眼镜命令提交失败；请检查眼镜录音指示"); return false }
    }
    private func preservePartial() {
        if !partial.isEmpty { sink?.event(CaptionEntry(kind: .unfinished, text: partial)) }
        partial = ""
    }
    func stop(reason: String = "用户停止") {
        guard active, phase != .stopping else { return }
        let hadAudio = clock != nil
        phase = .stopping; generation = UUID(); timer?.invalidate(); timer = nil
        provider?.stop(); key = ""; retryAt = nil; cloudDeadline = nil; dirtyDisplay = false
        preservePartial()
        var note = reason
        if hadAudio, let target {
            // Both commands are best effort; local recording/upload always stops.
            do { try voice.sendCaption(target: target, payload: AssistantRecorderPrototype.control(start: false)) }
            catch { note += "；无法确认眼镜停止采音" }
            do { try voice.sendCaption(target: target, payload: AssistantExitPrototype.normalExit()) }
            catch { note += "；无法确认眼镜退出" }
        }
        #if COMPANION_DEVICE
        if let decoder { RNVoiceVADDestroy(decoder); self.decoder = nil }
        #endif
        clock = nil; target = nil; voice.ownVoiceForCaptions(false)
        status = note
        // A finite background task protects only a final flush, NOT continuous recording.
        flushTask = UIApplication.shared.beginBackgroundTask(withName: "Caption journal flush") { [weak self] in
            Task { @MainActor in self?.endFlushTask() }
        }
        guard let output = sink else { phase = .idle; endFlushTask(); return }
        sink = nil; output.event(CaptionEntry(kind: .stopped, text: note))
        output.close { [weak self] in
            self?.phase = .idle; self?.endFlushTask()
        }
    }
    private func endFlushTask() {
        guard flushTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(flushTask); flushTask = .invalid
    }
}
