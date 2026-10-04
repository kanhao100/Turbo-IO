import Foundation
import Combine
import RayNeoCaptions
import RayNeoDisplay

@MainActor protocol SpeechPrompterTransport: AnyObject {
    var deviceID: String? { get }
    var ready: Bool { get }
    var sessionID: String? { get }
    var prepared: Bool { get }
    var started: Bool { get }
    var errorMessage: String? { get }
    var onProgress: ((Int, Int) -> Void)? { get set }
    var onControl: ((UInt32) -> Void)? { get set }
    var onAudio: ((Data, Int?) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func prepare(text: String, scrollMode: Int, initialOffset: Int) -> Bool
    func start() -> Bool
    func seek(page: Int, highlight: Int) -> Bool
    func stop()
}

@MainActor protocol SpeechPrompterMicrophone: AnyObject {
    var onPCM: ((Data) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start(input: SpeechPrompterRuntime.Input) async throws -> String
    func stop()
}

@MainActor private final class FeatureSpeechPrompterTransport: SpeechPrompterTransport {
    let features: CompanionDeviceFeatures
    var deviceID: String? { features.voice.deviceID }
    var ready: Bool { features.voice.ready }
    var sessionID: String? { features.teleprompterID }
    var prepared: Bool { features.teleprompterPrepared }
    var started: Bool { features.teleprompterStarted }
    var errorMessage: String? { features.error }
    var onProgress: ((Int, Int) -> Void)?
    var onControl: ((UInt32) -> Void)?
    var onAudio: ((Data, Int?) -> Void)?
    var onFailure: ((String) -> Void)?
    init(_ features: CompanionDeviceFeatures) {
        self.features = features
        features.onTeleprompterProgress = { [weak self] value in
            self?.onProgress?(Int(value.pageOffset), Int(value.highLightOffset))
        }
        features.onTeleprompterControl = { [weak self] in self?.onControl?($0) }
        features.onTeleprompterAudio = { [weak self] in self?.onAudio?($0, $1) }
        features.onTeleprompterFailure = { [weak self] in self?.onFailure?($0) }
    }
    func prepare(text: String, scrollMode: Int, initialOffset: Int) -> Bool {
        features.prepareTeleprompter(text, speed: 120, scrollMode: scrollMode, initialOffset: initialOffset)
        return features.teleprompterID != nil && features.error == nil
    }
    func start() -> Bool {
        features.teleprompterControl(3)
        return features.error == nil
    }
    func seek(page: Int, highlight: Int) -> Bool {
        features.teleprompterSeek(pageOffset: page, highlightOffset: highlight)
    }
    func stop() { features.teleprompterControl(6) }
}

#if COMPANION_DEVICE
@MainActor private final class DevicePrompterMicrophone: SpeechPrompterMicrophone {
    private let capture = SubtitleMicrophoneInput()
    var onPCM: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    init() {
        capture.onPCM = { [weak self] in self?.onPCM?($0) }
        capture.onFailure = { [weak self] in self?.onFailure?($0) }
    }
    func start(input: SpeechPrompterRuntime.Input) async throws -> String {
        let uid: String?
        if input == .iPhone {
            let ports = try await SubtitleMicrophoneInput.availablePorts()
            guard let builtIn = ports.first(where: { $0.isBuiltIn }) else { throw DeviceFeatureError.incomplete }
            uid = builtIn.uid
        } else { uid = nil }
        let actual = try await capture.start(preferredUID: uid)
        return actual.name
    }
    func stop() { capture.stop() }
}
#endif

/// One manuscript, one audio input, one recognizer. Moving a reading anchor does
/// not alter any of those owners; only explicit end or an unrecoverable failure
/// closes capture. The displayed manuscript is an immutable session snapshot.
@MainActor final class SpeechPrompterRuntime: ObservableObject {
    enum Phase: String { case idle, preparing, listening }
    enum Output: String, CaseIterable {
        case phone, glasses
        var name: String { self == .phone ? "手机提词" : "眼镜提词" }
    }
    enum Input: String, CaseIterable {
        case glasses, iPhone, systemMicrophone
        var name: String {
            switch self {
            case .glasses: return "眼镜麦克风"
            case .iPhone: return "iPhone 麦克风"
            case .systemMicrophone: return "系统 / 领夹麦克风"
            }
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "选择稿件，准备开始演讲"
    @Published private(set) var error: String?
    @Published private(set) var confirmedUTF8Offset = 0
    @Published private(set) var candidateUTF8Offset: Int?
    @Published private(set) var followState: SpeechFollowState = .waiting
    @Published private(set) var microphoneRoute: String?
    @Published private(set) var recognitionText = ""
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var documentID: UUID?
    @Published private(set) var text = ""
    var onPosition: ((UUID, Int) -> Void)?
    var active: Bool { phase != .idle }
    var canStart: Bool { !active && available() && transport.sessionID == nil }
    private let settings: SubtitleSettingsStore
    private let transport: any SpeechPrompterTransport
    private let available: () -> Bool
    private let makeMicrophone: () -> (any SpeechPrompterMicrophone)?
    private let makeDecoder: () -> SubtitlePCMDecoder?
    private let uptime: () -> TimeInterval
    private let scheduleTimers: Bool
    private var output: Output = .phone
    private var input: Input = .iPhone
    private var provider: CaptionASRProvider?
    private var microphone: (any SpeechPrompterMicrophone)?
    private var decoder: SubtitlePCMDecoder?
    private var follower: SpeechScriptFollower?
    private var sessionOptions = CaptionOptions()
    private var sessionKey = ""
    private var generation = UUID(), recognitionGeneration = UUID()
    private var deviceAtStart: String?, ownedSession: String?
    private var asrReady = false
    private var retry = CaptionRetryBudget()
    private var retryAt: TimeInterval?
    private var recognitionDeadline: TimeInterval = 0
    private var bufferedPCM = Data()
    private var lastAudioAt: TimeInterval = 0
    private var lastAudioSequence: Int?
    private var lastSentAt: TimeInterval = -.infinity
    private var pendingPosition: (page: Int, highlight: Int)?
    private var pendingPositionIsManual = false
    private var recentSentPositions: [(page: Int, highlight: Int, at: TimeInterval)] = []
    private var sendingPosition: (page: Int, highlight: Int)?
    private var lastPersistedAt: TimeInterval = -.infinity
    private var lastPersistedOffset: Int?
    private var timer: Timer?
    private var now: TimeInterval { uptime() }
    func canStart(output: Output, input: Input) -> Bool {
        guard canStart, settings.requirements.isEmpty,
              (try? settings.options.validated()) != nil,
              input != .glasses || output == .glasses,
              output != .glasses || (transport.ready && transport.deviceID != nil) else { return false }
        #if COMPANION_DEVICE
        return true
        #else
        return settings.allowsChanges // Only injected source-build tests allow changes.
        #endif
    }

    init(settings: SubtitleSettingsStore, features: CompanionDeviceFeatures,
         available: @escaping () -> Bool, defaults: UserDefaults = .standard,
         transport: (any SpeechPrompterTransport)? = nil,
         makeMicrophone: (() -> (any SpeechPrompterMicrophone)?)? = nil,
         makeDecoder: (() -> SubtitlePCMDecoder?)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleTimers: Bool = true) {
        self.settings = settings; self.transport = transport ?? FeatureSpeechPrompterTransport(features)
        self.available = available; self.uptime = uptime; self.scheduleTimers = scheduleTimers
        self.makeMicrophone = makeMicrophone ?? {
            #if COMPANION_DEVICE
            return DevicePrompterMicrophone()
            #else
            return nil
            #endif
        }
        self.makeDecoder = makeDecoder ?? {
            #if COMPANION_DEVICE
            return NativeSubtitlePCMDecoder()
            #else
            return nil
            #endif
        }
        _ = defaults
    }
    deinit { timer?.invalidate() }

    @discardableResult func start(document: PrompterManuscript, output: Output, input: Input) -> Task<Void, Never>? {
        guard canStart else { error = "请先结束当前字幕、录音或提词会话。"; return nil }
        guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.text.count <= 12_000, document.text.utf8.count <= 48_000 else {
            error = "稿件为空或过长，请编辑为不超过 12,000 字的演讲稿。"; return nil
        }
        guard input != .glasses || output == .glasses else {
            error = "使用眼镜麦克风时，请选择眼镜提词。"; return nil
        }
        guard output != .glasses || (transport.ready && transport.deviceID != nil) else {
            error = "请先连接并认证眼镜。"; return nil
        }
        guard let configuration = settings.recognizer() else {
            error = "请先在转写设置中配置识别服务和语言。"; return nil
        }
        self.output = output; self.input = input
        generation = UUID(); let token = generation
        phase = .preparing; error = nil; status = "正在准备稿件和识别服务"
        documentID = document.id; text = document.text; recognitionText = ""
        follower = SpeechScriptFollower(text: text)
        apply(follower!.assist(toUTF8Offset: document.readingUTF8Offset), sendPosition: false)
        candidateUTF8Offset = nil; microphoneRoute = nil; audioLevel = 0
        deviceAtStart = output == .glasses ? transport.deviceID : nil
        ownedSession = nil; pendingPosition = nil; recentSentPositions = []
        lastSentAt = -.infinity; lastAudioAt = now; lastAudioSequence = nil
        lastPersistedAt = now; lastPersistedOffset = confirmedUTF8Offset
        retry = CaptionRetryBudget(); retryAt = nil; bufferedPCM = Data()
        sessionOptions = configuration.options; sessionKey = configuration.key
        provider = configuration.provider
        installTransportCallbacks(token: token)
        return Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { if self.generation == token { self.stop() }; return }
            do {
                if output == .glasses {
                    guard self.transport.prepare(text: self.text, scrollMode: input == .glasses ? 1 : 3,
                                                 initialOffset: self.confirmedUTF8Offset) else {
                        throw PrompterError.message(self.transport.errorMessage ?? "稿件发送失败。")
                    }
                    self.ownedSession = self.transport.sessionID
                    guard await self.waitFor(token: token, seconds: 45, condition: { self.transport.prepared }) else { return }
                }
                #if COMPANION_DEVICE
                if self.sessionOptions.service == .appleLocal {
                    try await AppleLocalCaptionASR.prepare(localeIdentifier: self.sessionOptions.language)
                    guard self.generation == token, self.active else { return }
                }
                #endif
                self.startRecognizer(token: token)
                guard await self.waitFor(token: token, seconds: 20, condition: { self.asrReady }) else { return }
                if input == .glasses {
                    guard let decoder = self.makeDecoder() else { throw PrompterError.message("无法准备眼镜音频解码。") }
                    self.decoder = decoder; decoder.reset(); self.microphoneRoute = "眼镜麦克风"
                }
                if output == .glasses {
                    guard self.transport.start() else { throw PrompterError.message("眼镜未能开始提词。") }
                    guard await self.waitFor(token: token, seconds: 10, condition: { self.transport.started }) else { return }
                }
                if input != .glasses {
                    guard let capture = self.makeMicrophone() else {
                        throw PrompterError.message("当前构建仅可预览稿件，请使用设备版开始收音。")
                    }
                    self.microphone = capture
                    capture.onPCM = { [weak self] pcm in
                        guard let self, self.generation == token else { return }; self.acceptPCM(pcm)
                    }
                    capture.onFailure = { [weak self] reason in
                        guard let self, self.generation == token else { return }; self.fail(reason)
                    }
                    let route = try await capture.start(input: input)
                    guard self.generation == token, self.active, !Task.isCancelled else {
                        capture.stop(); if self.generation == token { self.stop() }; return
                    }
                    self.microphoneRoute = route
                }
                guard self.generation == token, self.active, !Task.isCancelled else {
                    if self.generation == token { self.stop() }; return
                }
                self.phase = .listening; self.lastAudioAt = self.now
                self.status = "正在聆听 · 滑动可辅助定位"
                self.queuePosition(); self.installTimer()
            } catch {
                guard self.generation == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func waitFor(token: UUID, seconds: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = now + seconds
        while generation == token, active, !condition(), now < deadline, !Task.isCancelled {
            if let retryAt, now >= retryAt { self.retryAt = nil; startRecognizer(token: token) }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        }
        guard generation == token, active else { return false }
        guard !Task.isCancelled else { stop(); return false }
        guard condition() else { fail("准备或连接超时；已保持阅读位置，请检查连接后重新开始。"); return false }
        return true
    }

    private func installTransportCallbacks(token: UUID) {
        transport.onProgress = { [weak self] page, highlight in
            guard let self, self.generation == token, self.active, self.output == .glasses else { return }
            self.eyePosition(page: page, highlight: highlight)
        }
        transport.onControl = { [weak self] type in
            guard let self, self.generation == token, self.active, self.output == .glasses else { return }
            if type == 4 { self.pauseFollowing() }
            else if type == 5 { self.resumeFollowing() }
            else if type == 6 { self.stop(notifyGlasses: false) }
        }
        transport.onAudio = { [weak self] encoded, sequence in
            guard let self, self.generation == token, self.active, self.input == .glasses else { return }
            guard self.transport.started, self.transport.sessionID == self.ownedSession,
                  self.transport.deviceID == self.deviceAtStart else { return }
            guard let decoder = self.decoder else { return } // No audio accepted before the owned start.
            if let sequence {
                guard self.lastAudioSequence.map({ sequence > $0 }) ?? true else { return }
                self.lastAudioSequence = sequence
            }
            guard let pcm = decoder.decode(encoded) else {
                self.fail("眼镜音频格式未通过校验；已保持稿件位置。"); return
            }
            self.acceptPCM(pcm)
        }
        transport.onFailure = { [weak self] reason in
            guard let self, self.generation == token, self.active, self.output == .glasses else { return }
            self.fail(reason)
        }
    }

    private func startRecognizer(token: UUID) {
        recognitionGeneration = UUID(); let recognitionToken = recognitionGeneration
        asrReady = false; recognitionDeadline = now + 20
        provider?.onReady = { [weak self] in
            guard let self, self.generation == token, self.recognitionGeneration == recognitionToken, self.active else { return }
            self.asrReady = true; self.retryAt = nil
            let buffered = self.bufferedPCM; self.bufferedPCM = Data()
            if !buffered.isEmpty { self.provider?.append(buffered) }
        }
        provider?.onText = { [weak self] recognized, final in
            guard let self, self.generation == token, self.recognitionGeneration == recognitionToken,
                  self.phase == .listening, recognized.utf8.count <= 32_768 else { return }
            self.retry.recognized(); self.recognitionText = recognized
            if let update = self.follower?.recognize(recognized, final: final) { self.apply(update) }
        }
        provider?.onEndpoint = nil
        provider?.onFailure = { [weak self] failure in
            guard let self, self.generation == token, self.recognitionGeneration == recognitionToken, self.active else { return }
            self.recognitionFailed(failure)
        }
        provider?.start(options: sessionOptions, key: sessionKey)
    }

    private func acceptPCM(_ pcm: Data) {
        guard active, !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 64_000 else { return }
        lastAudioAt = now
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        audioLevel = min(1, sqrt(samples.reduce(0) { $0 + pow(Double($1) / 32768, 2) } / Double(samples.count)) * 5)
        if asrReady { provider?.append(pcm) }
        else {
            bufferedPCM.append(pcm)
            if bufferedPCM.count > 64_000 {
                bufferedPCM.removeFirst(bufferedPCM.count - 64_000)
                if let update = follower?.resetRecognitionEvidence() { apply(update, sendPosition: false) }
            }
        }
    }
    private func recognitionFailed(_ failure: CaptionConnectionFailure) {
        guard failure.canRetry, let delay = retry.nextDelay() else { fail(failure.message); return }
        asrReady = false; recognitionGeneration = UUID(); provider?.onFailure = nil; provider?.stop()
        if let update = follower?.resetRecognitionEvidence() { apply(update, sendPosition: false) }
        pendingPosition = nil; retryAt = now + delay
        status = "识别连接中断，位置保持；正在恢复识别"
    }

    func assist(toUTF8Offset offset: Int) {
        guard active, let update = follower?.assist(toUTF8Offset: offset) else { return }
        pendingPosition = nil; apply(update, sendPosition: false)
        queuePosition(manual: true); persistPosition(force: true)
        status = followState == .paused ? "跟随已暂停 · 识别继续" : "已辅助定位 · 继续聆听附近稿件"
    }
    func pauseFollowing() {
        guard active, let update = follower?.pause() else { return }
        pendingPosition = nil; apply(update, sendPosition: false)
        status = "跟随已暂停 · 识别继续"
        persistPosition(force: true)
    }
    func resumeFollowing() {
        guard active, let update = follower?.resume() else { return }
        apply(update, sendPosition: false)
        status = "继续聆听 · 等待附近稿件重新匹配"
    }
    private func apply(_ update: SpeechFollowUpdate, sendPosition: Bool = true) {
        let changed = confirmedUTF8Offset != update.confirmedUTF8Offset
        confirmedUTF8Offset = update.confirmedUTF8Offset
        candidateUTF8Offset = update.candidateUTF8Offset
        followState = update.state
        if phase == .listening {
            switch update.state {
            case .waiting: status = "正在聆听 · 等待匹配当前稿件"
            case .following: status = "跟随中 · 滑动可辅助定位"
            case .uncertain: status = "暂时对不上 · 位置保持，识别继续"
            case .paused: status = "跟随已暂停 · 识别继续"
            case .finished: status = "已到稿件末尾 · 识别继续，可滑动回读"
            }
        }
        if sendPosition, changed {
            if update.shouldMove { queuePosition() }
            else { pendingPosition = nil }
        }
        if update.state == .uncertain || update.state == .paused { pendingPosition = nil }
        persistPosition(force: false)
    }
    private func queuePosition(manual: Bool = false) {
        guard output == .glasses, active else { return }
        let offsets = PrompterViewportMap.lineStarts(text)
        let line = offsets.lastIndex(where: { $0 <= confirmedUTF8Offset }) ?? 0
        let page = offsets[max(0, line - 1)]
        pendingPosition = (page, confirmedUTF8Offset)
        pendingPositionIsManual = manual
        pumpPosition()
    }
    private func pumpPosition() {
        guard phase == .listening, output == .glasses,
              (followState != .paused || pendingPositionIsManual), let pending = pendingPosition,
              now - lastSentAt >= 0.5 else { return }
        guard transport.deviceID == deviceAtStart, transport.sessionID == ownedSession,
              transport.prepared, transport.started else { fail("眼镜提词会话已变化；位置保持，请重新开始。"); return }
        sendingPosition = pending
        let submitted = transport.seek(page: pending.page, highlight: pending.highlight)
        sendingPosition = nil
        guard submitted else {
            fail(transport.errorMessage ?? "眼镜位置指令未能发送；已保持稿件。"); return
        }
        lastSentAt = now; pendingPosition = nil; pendingPositionIsManual = false
        recentSentPositions.append((pending.page, pending.highlight, now))
        recentSentPositions = Array(recentSentPositions.filter { now - $0.at <= 5 }.suffix(16))
    }
    private func eyePosition(page: Int, highlight: Int) {
        guard page >= 0, page <= text.utf8.count, highlight >= 0, highlight <= text.utf8.count else { return }
        if sendingPosition.map({ $0.page == page && $0.highlight == highlight }) == true ||
            recentSentPositions.contains(where: { $0.page == page && $0.highlight == highlight && now - $0.at <= 5 }) {
            return // A programmatic seek echo must not reset recognition evidence.
        }
        pendingPosition = nil
        guard let update = follower?.assist(toUTF8Offset: page) else { return }
        apply(update, sendPosition: false); persistPosition(force: true)
        // The hardware already moved. No seek is sent back for a user swipe.
        status = followState == .paused ? "跟随已暂停 · 识别继续" : "眼镜滑动已辅助定位 · 识别继续"
    }
    private func persistPosition(force: Bool) {
        guard let documentID, lastPersistedOffset != confirmedUTF8Offset,
              force || now - lastPersistedAt >= 2 else { return }
        onPosition?(documentID, confirmedUTF8Offset)
        lastPersistedOffset = confirmedUTF8Offset; lastPersistedAt = now
    }
    func stop() { stop(notifyGlasses: true) }
    private func stop(notifyGlasses: Bool) {
        guard active else { return }
        persistPosition(force: true)
        generation = UUID(); recognitionGeneration = UUID(); phase = .idle
        timer?.invalidate(); timer = nil
        provider?.onText = nil; provider?.onFailure = nil; provider?.stop(); provider = nil
        microphone?.stop(); microphone = nil; decoder = nil
        transport.onAudio = nil; transport.onProgress = nil; transport.onControl = nil; transport.onFailure = nil
        if notifyGlasses, output == .glasses, transport.sessionID == ownedSession { transport.stop() }
        ownedSession = nil; retryAt = nil; bufferedPCM = Data(); pendingPosition = nil
        sessionKey = ""; asrReady = false; audioLevel = 0
        status = error == nil ? "演讲已结束，阅读位置已保存" : "跟随已停止，稿件和阅读位置已保留"
    }
    private func fail(_ message: String) { error = message; stop() }
    func tick() {
        guard phase == .listening else { return }
        if output == .glasses, transport.deviceID != deviceAtStart { fail("眼镜连接中断；已保持阅读位置。"); return }
        if now - lastAudioAt >= 15 { fail("长时间没有收到音频，请检查所选麦克风。"); return }
        if let retryAt, now >= retryAt { self.retryAt = nil; startRecognizer(token: generation) }
        if !asrReady, retryAt == nil, now >= recognitionDeadline { recognitionFailed(.connection) }
        pumpPosition(); persistPosition(force: false)
    }
    private func installTimer() {
        guard scheduleTimers else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private enum PrompterError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

/// Approximate viewport anchors in original UTF-8 bytes. Native typography can
/// normalize these further; every requested offset remains a grapheme boundary.
enum PrompterViewportMap {
    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0], byteOffset = 0, width = 0
        for character in text {
            if character.isNewline {
                byteOffset += String(character).utf8.count; starts.append(byteOffset); width = 0
                continue
            }
            let wide = character.unicodeScalars.contains {
                $0.properties.isEmojiPresentation || (0x2E80...0xA4CF).contains($0.value) ||
                (0xAC00...0xD7A3).contains($0.value) || (0xFF00...0xFF60).contains($0.value)
            }
            let nextWidth = wide ? 280 : 100
            if width + nextWidth > 5600 {
                starts.append(byteOffset); width = 0
            }
            width += nextWidth; byteOffset += String(character).utf8.count
        }
        return starts
    }
}
