import Foundation
import AVFAudio

/// Captures an iPhone or system-routed microphone for the subtitle pipeline.
/// `onPCM` receives 16 kHz, mono, signed 16-bit little-endian PCM on the main actor.
/// A selected port is verified against `currentRoute`; route changes require a new start.
@MainActor final class SubtitleMicrophoneInput {
    struct Port: Hashable {
        let uid: String
        let name: String
        let type: String

        var isBuiltIn: Bool { type == AVAudioSession.Port.builtInMic.rawValue }
    }

    var onPCM: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private struct SessionSnapshot {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let preferredUID: String?
    }

    private enum InputError: LocalizedError {
        case alreadyRunning, cancelled, denied, unavailable, routeMismatch, unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "麦克风采集已经在运行。"
            case .cancelled: return "麦克风采集已取消。"
            case .denied: return "没有麦克风权限，请在系统设置中允许录音。"
            case .unavailable: return "所选麦克风当前不可用。"
            case .routeMismatch: return "系统未切换到所选麦克风，请检查音频输入路由。"
            case .unsupportedFormat: return "当前麦克风没有提供可转换的 PCM 音频格式。"
            }
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var worker: SubtitleMicrophonePCMWorker?
    private var snapshot: SessionSnapshot?
    private var tapInstalled = false
    private var sessionActivated = false
    private var observers: [NSObjectProtocol] = []
    private var starting = false
    private var runToken: UUID?
    private var selectedInputUID: String?

    /// Lists record input ports; this does not ask for recording permission or start capture.
    /// Call while no other app audio operation is active because AVAudioSession is process-wide.
    static func availablePorts() async throws -> [Port] {
        let session = AVAudioSession.sharedInstance()
        let priorCategory = session.category
        let priorMode = session.mode
        let priorOptions = session.categoryOptions
        let needsConfiguration = (priorCategory != .playAndRecord && priorCategory != .record)
            || !priorOptions.contains(.allowBluetoothHFP)
        if needsConfiguration {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetoothHFP, .mixWithOthers])
        }
        defer {
            if needsConfiguration {
                try? session.setCategory(priorCategory, mode: priorMode, options: priorOptions)
            }
        }
        return (session.availableInputs ?? []).map(Self.port)
    }

    /// `nil` follows the current system microphone. Pass the built-in port UID to force
    /// the iPhone microphone, or another UID from `availablePorts()` to select that input.
    @discardableResult
    func start(preferredUID: String?) async throws -> Port {
        guard !starting, engine == nil else { throw InputError.alreadyRunning }
        starting = true
        let token = UUID()
        runToken = token
        defer { if runToken == token { starting = false } }

        onDiagnostic?("mic.permission=requested")
        let granted = await AVAudioApplication.requestRecordPermission()
        guard runToken == token else { throw InputError.cancelled }
        guard granted else {
            runToken = nil; starting = false
            onDiagnostic?("mic.permission=denied")
            throw InputError.denied
        }
        onDiagnostic?("mic.permission=granted")

        snapshot = SessionSnapshot(category: session.category, mode: session.mode,
                                   options: session.categoryOptions,
                                   preferredUID: session.preferredInput?.uid)
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
            sessionActivated = true
            guard runToken == token else { throw InputError.cancelled }

            if let preferredUID {
                guard let requested = session.availableInputs?.first(where: { $0.uid == preferredUID }) else {
                    throw InputError.unavailable
                }
                try session.setPreferredInput(requested)
                onDiagnostic?("mic.route=requested type=\(requested.portType.rawValue)")
            } else {
                // A preferred route from an earlier capture must not override "system" mode.
                try session.setPreferredInput(nil)
                onDiagnostic?("mic.route=requested type=system")
            }
            let actual = try await awaitRoute(preferredUID: preferredUID, token: token)
            let port = Self.port(actual)
            selectedInputUID = actual.uid
            onDiagnostic?("mic.route=active type=\(port.type)")

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
                throw InputError.unsupportedFormat
            }
            onDiagnostic?("mic.format=input rate=\(Int(format.sampleRate)) channels=\(format.channelCount) float32")

            let worker = try SubtitleMicrophonePCMWorker(inputFormat: format,
                deliver: { [weak self] pcm, done in
                    Task { @MainActor [weak self] in
                        defer { done() }
                        guard let self, self.runToken == token else { return }
                        self.onPCM?(pcm)
                    }
                },
                fail: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        guard let self, self.runToken == token else { return }
                        self.fail(reason)
                    }
                })
            self.worker = worker
            self.engine = engine
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [worker] buffer, _ in
                worker.enqueue(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            guard runToken == token else { throw InputError.cancelled }
            guard session.currentRoute.inputs.first?.uid == actual.uid else { throw InputError.routeMismatch }
            installObservers()
            onDiagnostic?("mic.capture=started output=pcm_s16le_16000_mono")
            return port
        } catch {
            // `stop()` may have cancelled this start while it awaited a route change.
            // Do not tear down a newer capture started in the meantime.
            if runToken == token { stop() }
            throw error
        }
    }

    private func awaitRoute(preferredUID: String?, token: UUID) async throws -> AVAudioSessionPortDescription {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        var lastUID: String?
        var stableChecks = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard runToken == token else { throw InputError.cancelled }
            if let actual = session.currentRoute.inputs.first {
                if let preferredUID {
                    if actual.uid == preferredUID { return actual }
                } else {
                    // Clearing a previous preferred input can also change routes later.
                    // Accept the system route after it remains stable for about 200 ms.
                    if actual.uid == lastUID { stableChecks += 1 }
                    else { lastUID = actual.uid; stableChecks = 0 }
                    if stableChecks >= 4 { return actual }
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard runToken == token else { throw InputError.cancelled }
        throw preferredUID == nil ? InputError.unavailable : InputError.routeMismatch
    }

    func stop() {
        runToken = nil
        starting = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        worker?.close()
        worker = nil
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        engine = nil
        tapInstalled = false
        selectedInputUID = nil
        restoreSession()
        onDiagnostic?("mic.capture=stopped")
    }

    private func installObservers() {
        guard let token = runToken else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.runToken == token else { return }
                self.routeChanged(notification)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.runToken == token else { return }
                self.interrupted(notification)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.runToken == token, self.engine != nil else { return }
                self.fail("录音设备配置已改变，请重新开始字幕。")
            }
        })
    }

    private func routeChanged(_ notification: Notification) {
        guard engine != nil, let selectedInputUID else { return }
        let actualUID = session.currentRoute.inputs.first?.uid
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        onDiagnostic?("mic.route=changed reason=\(String(describing: reason)) input_changed=\(actualUID != selectedInputUID)")
        guard actualUID != selectedInputUID else { return }
        // Reopening deliberately requires a new, visible choice; there is no silent fallback.
        fail("录音路由已改变，请确认当前麦克风后重新开始字幕。")
    }

    private func interrupted(_ notification: Notification) {
        guard engine != nil else { return }
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
        onDiagnostic?("mic.interruption=began")
        fail("录音被系统中断，请重新开始字幕。")
    }

    private func fail(_ reason: String) {
        guard engine != nil else { return }
        onDiagnostic?("mic.failure=\(reason)")
        stop()
        onFailure?(reason)
    }

    private func restoreSession() {
        guard let snapshot else { return }
        self.snapshot = nil
        let didActivate = sessionActivated
        sessionActivated = false
        // Another owner may have reconfigured the process-wide session in the meantime.
        guard session.category == .playAndRecord, session.mode == .default,
              session.categoryOptions == [.allowBluetoothHFP, .mixWithOthers] else {
            onDiagnostic?("mic.session=restore_skipped_external_change")
            return
        }
        let previous = snapshot.preferredUID.flatMap { uid in
            session.availableInputs?.first(where: { $0.uid == uid })
        }
        do { try session.setPreferredInput(previous) }
        catch { onDiagnostic?("mic.session=preferred_input_restore_failed error=\(error.localizedDescription)") }
        if didActivate {
            do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
            catch { onDiagnostic?("mic.session=deactivate_failed error=\(error.localizedDescription)") }
        }
        do {
            try session.setCategory(snapshot.category, mode: snapshot.mode, options: snapshot.options)
            onDiagnostic?("mic.session=restored")
        } catch {
            onDiagnostic?("mic.session=category_restore_failed error=\(error.localizedDescription)")
        }
    }

    private static func port(_ value: AVAudioSessionPortDescription) -> Port {
        Port(uid: value.uid, name: value.portName, type: value.portType.rawValue)
    }
}

/// AVAudioConverter is confined to one serial queue. The audio tap only copies input;
/// bounded conversion and main-delivery queues fail the session instead of dropping audio.
private final class SubtitleMicrophonePCMWorker {
    typealias Delivery = (Data, @escaping () -> Void) -> Void

    private let queue = DispatchQueue(label: "io.turboio.subtitle.microphone.convert", qos: .userInitiated)
    private let lock = NSLock()
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let deliver: Delivery
    private let fail: (String) -> Void
    private var pendingBuffers = 0
    private var pendingDeliveries = 0
    private var closed = false
    private static let maximumPending = 16

    init(inputFormat: AVAudioFormat, deliver: @escaping Delivery, fail: @escaping (String) -> Void) throws {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "SubtitleMicrophoneInput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法转换麦克风音频为 16 kHz PCM。"])
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.converter.downmix = true
        self.deliver = deliver
        self.fail = fail
    }

    func enqueue(_ input: AVAudioPCMBuffer) {
        lock.lock()
        if closed { lock.unlock(); return }
        if pendingBuffers >= Self.maximumPending {
            lock.unlock()
            signalFailure("麦克风音频转换跟不上输入，已停止以避免丢失字幕音频。")
            return
        }
        pendingBuffers += 1
        lock.unlock()

        guard input.format.sampleRate == inputFormat.sampleRate,
              input.format.channelCount == inputFormat.channelCount,
              input.format.commonFormat == .pcmFormatFloat32,
              !input.format.isInterleaved,
              let from = input.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: input.frameLength),
              let to = copy.floatChannelData else {
            finishBuffer()
            signalFailure("麦克风输入格式在录制期间改变，请重新开始字幕。")
            return
        }
        copy.frameLength = input.frameLength
        let byteCount = Int(input.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(inputFormat.channelCount) {
            memcpy(to[channel], from[channel], byteCount)
        }
        queue.async { [self] in
            defer { finishBuffer() }
            convert(copy)
        }
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        var supplied = false
        let estimatedFrames = max(256, Int(ceil(Double(input.frameLength) * 16_000 / inputFormat.sampleRate)) + 128)
        let outputCapacity = AVAudioFrameCount(min(8_192, estimatedFrames))
        for _ in 0..<16 {
            lock.lock(); let isClosed = closed; lock.unlock()
            if isClosed { return }
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                signalFailure("无法分配麦克风音频缓冲区。")
                return
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                signalFailure("麦克风音频转换失败：\(conversionError?.localizedDescription ?? "未知错误")")
                return
            }
            if output.frameLength > 0 {
                guard let samples = output.int16ChannelData?.pointee else {
                    signalFailure("麦克风音频转换未产生 PCM16 数据。")
                    return
                }
                let pcm = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
                lock.lock()
                let tooMany = pendingDeliveries >= Self.maximumPending
                if !closed && !tooMany { pendingDeliveries += 1 }
                let isClosed = closed
                lock.unlock()
                if isClosed { return }
                if tooMany {
                    signalFailure("字幕处理跟不上麦克风输入，已停止以避免音频积压。")
                    return
                }
                deliver(pcm) { [weak self] in self?.finishDelivery() }
            }
            if status == .inputRanDry || status == .endOfStream { return }
            if status == .haveData && output.frameLength == 0 { return }
        }
        signalFailure("麦克风音频转换缓冲区溢出，已停止本次录制。")
    }

    private func finishBuffer() {
        lock.lock(); pendingBuffers -= 1; lock.unlock()
    }

    private func finishDelivery() {
        lock.lock(); pendingDeliveries -= 1; lock.unlock()
    }

    private func signalFailure(_ reason: String) {
        lock.lock()
        let shouldNotify = !closed
        closed = true
        lock.unlock()
        if shouldNotify { fail(reason) }
    }
}
