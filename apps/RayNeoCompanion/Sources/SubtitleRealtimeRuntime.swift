import Foundation
import Combine
import UIKit
import RayNeoProtocol
import RayNeoCaptions

@MainActor protocol SubtitleRealtimeDevice: AnyObject {
    var supportsDevice: Bool { get }
    var deviceID: String? { get }
    var subtitleOwnsDisplay: Bool { get }
    var featureIsBusy: (() -> Bool)? { get }
    func prepare()
    func ownDisplayForSubtitles(_ owns: Bool)
    func sendRealtimeSubtitle(target: String, payload: Data) throws
}

protocol SubtitlePCMDecoder: AnyObject {
    func decode(_ packet: Data) -> Data?
    func reset()
}

#if COMPANION_DEVICE
private final class NativeSubtitlePCMDecoder: SubtitlePCMDecoder {
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
/// Stops upload and disk input immediately; remote exit uncertainty retains ownership.
@MainActor final class SubtitleRealtimeRuntime: ObservableObject {
    enum Phase: String { case idle, preparing, startingAudio, openingDisplay, listening, stopping, uncertain }
    typealias WriterFactory = (URL, SubtitleSessionRecord, @escaping () -> Void) async throws -> SubtitleSessionWriting
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "让眼镜听见的声音，变成看得见的字幕"
    @Published private(set) var partial = ""
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
    @Published private(set) var shortcutEnabled = false // Explicit opt-in each app launch.
    @Published private(set) var cloudReady = false
    let settings: SubtitleSettingsStore
    let archive: SubtitleArchiveStore
    var onShortcutStart: (() -> Void)?
    private let device: any SubtitleRealtimeDevice
    private let defaults: UserDefaults
    private let uptime: () -> TimeInterval
    private let makeDecoder: () -> SubtitlePCMDecoder?
    private let makeWriter: WriterFactory
    private let scheduleTimers: Bool
    private static let pendingKey = "companion.realtimeSubtitles.exitPending.v1"
    private var timer: Timer?, lifecycle: NSObjectProtocol?
    private var provider: CaptionASRProvider?, decoder: SubtitlePCMDecoder?, writer: SubtitleSessionWriting?
    private var record: SubtitleSessionRecord?, options = CaptionOptions(), key = ""
    private var target: String?, sid: String?, generation = UUID()
    private var deadline: TimeInterval = 0, began: TimeInterval = 0, lastAudioAt: TimeInterval = 0
    private var lastSequence: Int?, gapOpen = false, displayReady = false, cloudStarted = false
    private var pendingText: String?, lastDisplayAt: TimeInterval = -.infinity
    private var acceptedAt: TimeInterval = 0, cloudDeadline: TimeInterval = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var now: TimeInterval { uptime() }
    var active: Bool { phase != .idle }
    var canStart: Bool { !active && !saving && device.supportsDevice && device.deviceID != nil && !device.subtitleOwnsDisplay && device.featureIsBusy?() != true }
    var canStop: Bool { [.preparing, .startingAudio, .openingDisplay, .listening].contains(phase) }
    var canRetryExit: Bool { phase == .uncertain && target != nil && device.deviceID == target }
    var audioSeconds: TimeInterval { Double(audioBytes) / 32_000 }

    init(voice: any SubtitleRealtimeDevice, settings: SubtitleSettingsStore, archive: SubtitleArchiveStore,
         defaults: UserDefaults = .standard, makeDecoder: (() -> SubtitlePCMDecoder?)? = nil,
         makeWriter: WriterFactory? = nil, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleTimers: Bool = true) {
        device = voice; self.settings = settings; self.archive = archive; self.defaults = defaults
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
        if defaults.bool(forKey: Self.pendingKey) {
            phase = .uncertain; status = "上次字幕退出未确认，请先在眼镜退出字幕再确认。"
        }
        lifecycle = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    deinit { timer?.invalidate(); if let lifecycle { NotificationCenter.default.removeObserver(lifecycle) } }
    func prepare() {
        device.prepare(); settings.refresh()
        if active, phase == .uncertain, target == nil, !device.subtitleOwnsDisplay { device.ownDisplayForSubtitles(true) }
    }
    @discardableResult func start(consented: Bool) -> Task<Void, Never>? {
        prepare()
        guard consented, canStart else { error = "请先连接眼镜、结束其他任务，并确认上传与保存提示。"; return nil }
        return begin(deviceID: device.deviceID!, incomingSID: nil)
    }
    @discardableResult private func begin(deviceID: String, incomingSID: String?) -> Task<Void, Never>? {
        guard canStart, let config = settings.recognizer() else {
            error = "请先配置所选转写服务；字幕不需要 DeepSeek。"; return nil
        }
        guard let decoder = makeDecoder() else { error = "无法创建眼镜音频解码器。"; return nil }
        generation = UUID(); let token = generation
        let id = UUID(), protocolID = incomingSID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        target = deviceID; sid = protocolID; sessionID = id; options = config.options; key = config.key
        provider = config.provider; self.decoder = decoder; phase = .preparing; status = "正在准备本次字幕与音频存储"
        partial = ""; recent = []; elapsed = 0; audioBytes = 0; audioLevel = 0; packets = 0; gaps = 0
        lastSequence = nil; gapOpen = false; displayReady = false; cloudReady = false; cloudStarted = false
        lastDisplayAt = -.infinity; pendingText = nil; error = nil; acceptedAt = now; began = now
        device.ownDisplayForSubtitles(true)
        let value = SubtitleSessionRecord(id: id, title: "字幕 · " + Date().formatted(date: .abbreviated, time: .shortened), options: options)
        record = value
        let makeWriter = makeWriter, root = archive.root
        return Task {
            do {
                let output = try await makeWriter(root, value) { [weak self] in
                    Task { @MainActor in guard let self, self.generation == token else { return }; self.fail("本地保存失败；已收到的原文件保留。") }
                }
                guard generation == token, phase == .preparing else {
                    var cancelled = value; cancelled.state = .interrupted; cancelled.endedAt = Date(); cancelled.endReason = "准备阶段取消，未请求收音"
                    await withCheckedContinuation { continuation in output.finish(cancelled) { _ in continuation.resume() } }
                    return
                }
                writer = output
                guard device.deviceID == deviceID else { stop(reason: "准备时眼镜已断开", interrupted: true); return }
                writer?.event(CaptionEntry(kind: .started, text: "\(options.service.name) · \(options.language) · \(options.recordAudio ? "保存文本及音频" : "仅保存文本")"))
                defaults.set(true, forKey: Self.pendingKey)
                phase = .startingAudio; deadline = now + 10; lastAudioAt = now
                installTimer()
                if incomingSID != nil {
                    guard send(try SubtitleTranslateWire.startResult(sid: protocolID, language: options.language, saveAudio: options.recordAudio)) else { return }
                    guard generation == token, phase == .startingAudio else { return }
                    acceptedStart(); onShortcutStart?()
                } else {
                    status = "已请求字幕收音，等待眼镜确认"
                    _ = send(try SubtitleTranslateWire.start(sid: protocolID, language: options.language, saveAudio: options.recordAudio))
                }
            } catch { guard generation == token else { return }; fail("字幕准备失败，未完成启动。") }
        }
    }
    func setShortcut(_ enabled: Bool, consented: Bool) {
        guard !active, !saving, !enabled || consented else { return }
        settings.refresh()
        guard !enabled || settings.requirements.isEmpty else { error = "请先保存转写配置与密钥。"; return }
        shortcutEnabled = enabled
    }
    func receive(device source: String, packet: Data, arrival: TimeInterval) {
        guard source == device.deviceID, now >= arrival, now - arrival <= 0.75 else { return }
        guard let event = try? SubtitleTranslateWire.event(packet) else {
            if active, source == target { fail("字幕消息格式或音频长度不匹配，已停止本次会话。") }; return
        }
        if phase == .idle, event.type == 1 {
            guard shortcutEnabled, canStart else { return }
            _ = begin(deviceID: source, incomingSID: event.sid); return
        }
        guard active, source == target, event.sid == sid, arrival >= acceptedAt else { return }
        if (phase == .startingAudio || phase == .openingDisplay), now >= deadline {
            fail("字幕握手回应已超时，未根据迟到回包重新开启收音。")
            return
        }
        if event.type == 3 {
            // Could be pause or stop. End local capture immediately; physical exit is explicit.
            stop(reason: "眼镜发出字幕控制事件（\(event.reason.map(String.init) ?? "未知")）", interrupted: false)
            return
        }
        guard canStop, phase != .preparing else { return }
        if event.type == 2, phase == .startingAudio {
            guard event.code == 1 else { fail("眼镜未接受字幕启动，code=\(event.code.map(String.init) ?? "无效")。请检查冲突、佩戴和电量。"); return }
            acceptedStart()
        } else if event.type == 8, phase == .openingDisplay {
            guard event.code == 1 || event.code == 2 else { fail("眼镜未接受字幕显示配置。" ); return }
            displayReady = true; phase = .listening; status = "正在听 · \(options.service.name)"
            pumpDisplay()
        } else if event.type == 4, cloudStarted, phase == .openingDisplay || phase == .listening {
            acceptAudio(event, arrival: arrival)
        }
    }
    private func acceptedStart() {
        guard phase == .startingAudio, let sid else { return }
        phase = .openingDisplay; deadline = now + 10; lastAudioAt = now; cloudDeadline = now + 20
        status = "收音启动已确认，正在连接转写与字幕显示"
        let token = generation
        provider?.onReady = { [weak self] in guard let self, self.generation == token, self.cloudStarted else { return }; self.cloudReady = true }
        provider?.onText = { [weak self] text, final in guard let self, self.generation == token else { return }; self.recognized(text, final: final) }
        provider?.onFailure = { [weak self] failure in guard let self, self.generation == token else { return }; self.fail("\(self.options.service.name)：\(failure.message)") }
        provider?.onEndpoint = nil
        cloudStarted = true
        provider?.start(options: options, key: key)
        guard generation == token, phase == .openingDisplay else { return }
        do { _ = send(try SubtitleTranslateWire.display(sid: sid)) } catch { fail("无法编码显示命令。") }
    }
    private func acceptAudio(_ event: SubtitleTranslateWire.Event, arrival: TimeInterval) {
        guard let sequence = event.sequence else { return }
        if let previous = lastSequence {
            guard sequence > previous else { return }
            if sequence != previous + 1 { markGap("音频分片序号不连续，缺失部分未补录") }
        }
        lastSequence = sequence
        if event.audio == nil, event.end { stop(reason: "眼镜音频已结束"); return }
        guard let audio = event.audio, let pcm = decoder?.decode(audio), !pcm.isEmpty, pcm.count <= 3840, pcm.count % 2 == 0 else {
            markGap("音频包未通过 Opus 解码校验"); fail("眼镜字幕音频格式未通过解码；请分享诊断记录。") ; return
        }
        if arrival - lastAudioAt > 0.5 { markGap("音频到达间隔中断") }
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
        cloudReady = true; partial = value
        if final {
            if !value.isEmpty {
                let entry = CaptionEntry(kind: .final, text: value); recent.append(entry)
                if recent.count > 200 { recent.removeFirst(recent.count - 200) }
                record?.finalSentences += 1; record?.preview = String(value.prefix(180)); writer?.event(entry)
            }
            partial = ""
        }
        // Latest full window wins: coalescing cannot drop the last/final update.
        let tail = recent.suffix(2).map(\.text).joined(separator: "\n")
        let visible = final ? tail : [tail, value].filter { !$0.isEmpty }.joined(separator: "\n")
        pendingText = CaptionText.lensWindow(visible.isEmpty ? "正在聆听…" : visible, maximumBytes: 384)
        pumpDisplay()
    }
    private func pumpDisplay() {
        guard phase == .listening, displayReady, now - lastDisplayAt >= 0.5, let text = pendingText, let sid else { return }
        pendingText = nil; lastDisplayAt = now
        do { _ = send(try SubtitleTranslateWire.text(text, sid: sid)) } catch { fail("无法编码字幕文字。") }
    }
    private func markGap(_ note: String) {
        guard !gapOpen else { return }; gapOpen = true; gaps += 1; record?.gaps = gaps
        writer?.gap(); decoder?.reset(); writer?.event(CaptionEntry(kind: .gap, text: note))
    }
    func inputLost() { if cloudStarted { markGap("手机接收队列丢包") } }
    func connectionChanged() {
        guard active, let target, device.deviceID != target else { return }
        stop(reason: "连接中断，本次字幕已停止；请确认原眼镜退出。", interrupted: true)
        phase = .uncertain
    }
    func transportFailed(device source: String, packet: Data, code: Int) {
        guard source == target, let event = try? SubtitleTranslateWire.event(packet), event.sid == sid else { return }
        if event.type == 3 { phase = .uncertain; status = "退出发送失败，请在眼镜上退出后确认。" }
        else { fail("字幕命令异步发送失败，code=\(code)") }
    }
    private func send(_ packet: Data) -> Bool {
        guard let target, device.deviceID == target else { fail("眼镜连接已变化。" ); return false }
        do { try device.sendRealtimeSubtitle(target: target, payload: packet); return true }
        catch { fail("字幕命令未能提交，请确认眼镜状态。" ); return false }
    }
    private func fail(_ reason: String) { error = reason; stop(reason: reason, interrupted: true) }
    func stop(reason: String = "用户停止", interrupted: Bool = false) {
        guard canStop else { return }
        let wasPreparing = phase == .preparing
        generation = UUID(); phase = .stopping; deadline = now + 8; status = reason
        cloudStarted = false; provider?.stop(); provider = nil; key = ""; cloudReady = false; pendingText = nil
        decoder = nil; audioLevel = 0
        if !partial.isEmpty { writer?.event(CaptionEntry(kind: .unfinished, text: partial)); partial = "" }
        if !wasPreparing, let sid, let target, device.deviceID == target {
            do { try device.sendRealtimeSubtitle(target: target, payload: SubtitleTranslateWire.stop(sid: sid)) }
            catch { phase = .uncertain; status += "；退出提交失败" }
        }
        finishStorage(reason: reason, interrupted: interrupted)
        if wasPreparing { defaults.removeObject(forKey: Self.pendingKey); release() }
        else { status += "；请确认眼镜已退出"; installTimer() }
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
    func confirmExited() {
        guard phase == .stopping || phase == .uncertain else { return }
        defaults.removeObject(forKey: Self.pendingKey); release()
        status = saving ? "正在完成本机保存" : "字幕已结束，历史保存在此 App"
    }
    func retryExit() {
        guard canRetryExit, let target, let sid else { return }
        phase = .stopping; deadline = now + 8
        do { try device.sendRealtimeSubtitle(target: target, payload: SubtitleTranslateWire.stop(sid: sid)); status = "已重试退出，请核对镜片。" }
        catch { phase = .uncertain; status = "退出仍未提交，请在眼镜手动退出。" }
        installTimer()
    }
    private func release() {
        timer?.invalidate(); timer = nil; phase = .idle; target = nil; sid = nil
        record = nil; device.ownDisplayForSubtitles(false)
        if !saving { sessionID = nil }
    }
    func tick() {
        guard active else { return }
        if let target, device.deviceID != target { connectionChanged(); return }
        if phase == .stopping {
            if now >= deadline { phase = .uncertain; status = "本机已停止上传和保存输入；眼镜退出未确认。"; timer?.invalidate(); timer = nil }
            return
        }
        guard canStop, phase != .preparing else { return }
        elapsed = max(0, Int(now - began))
        if phase == .startingAudio || phase == .openingDisplay, now >= deadline { fail("10 秒未收到匹配的字幕启动或显示回执。" ); return }
        if elapsed >= options.maximumSeconds { stop(reason: "达到本次时长上限"); return }
        if cloudStarted, now - lastAudioAt >= 15 { fail("15 秒未收到有效眼镜音频；不是静音。" ); return }
        if cloudStarted, now - lastAudioAt >= 5 { markGap("等待眼镜音频恢复") }
        if cloudStarted, !cloudReady, now >= cloudDeadline { fail("转写连接超时，请检查服务配置和网络。" ); return }
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
        "Turbo IO 实时字幕\nphase=\(phase.rawValue) packets=\(packets) pcmBytes=\(audioBytes) gaps=\(gaps)\nASR=\(options.service.name) ready=\(cloudReady)\n\(status)\n\(error ?? "")\n不包含音频、正文、密钥或设备标识。"
    }
}
