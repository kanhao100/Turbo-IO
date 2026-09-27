import Foundation
import Combine

/// Bounded, metadata-only latency experiment. It never records text, audio, keys,
/// raw sequence numbers or device identifiers. All clocks use system uptime.
@MainActor final class SubtitleLatencyDiagnostics: ObservableObject {
    struct Snapshot: Equatable {
        var count = 0
        var last = 0
        var minimum = Int.max
        var maximum = 0
        var total: Int64 = 0

        var average: Int { count == 0 ? 0 : Int(total / Int64(count)) }
        mutating func add(_ milliseconds: Int) {
            let value = max(0, min(milliseconds, 600_000))
            count += 1; last = value; minimum = min(minimum, value)
            maximum = max(maximum, value); total += Int64(value)
        }
        var minimumValue: Int { count == 0 ? 0 : minimum }
    }

    enum Metric: String, CaseIterable, Hashable {
        case handshakeToFirstAudio = "眼镜启动确认 → 首个音频包"
        case audioArrivalInterval = "眼镜音频包到达间隔"
        case appDispatch = "接收回调 → App 主线程"
        case cloudReady = "启动云端 ASR → 服务就绪"
        case firstAudioToFirstResult = "首个 App 音频输入 → 首条结果"
        case audioToResult = "最近音频输入 → 结果（流式参考）"
        case resultInterval = "识别结果回调间隔"
        case resultToGlassesSubmit = "识别结果 → 眼镜发送提交"
    }

    @Published private(set) var enabled = false
    @Published private(set) var sessionCount = 0
    @Published private(set) var results: [Metric: Snapshot] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var serviceName = "尚未开始"

    private let defaults: UserDefaults
    private static let enabledKey = "companion.realtimeSubtitles.latencyExperiment.v1"
    private var accumulated: [Metric: Snapshot] = [:]
    private var lastPublishedAt: TimeInterval = -.infinity
    private var cloudBegan: TimeInterval?
    private var audioAccepted: TimeInterval?
    private var firstAudio: TimeInterval?
    private var latestAudio: TimeInterval?
    private var latestResult: TimeInterval?
    private var firstResultRecorded = false
    private var stoppedSessions = 0
    private var sessionsWithoutAudio = 0
    private var sessionsWithoutResult = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        if !value { clearTransient() }
    }
    func reset() {
        accumulated = [:]; results = [:]; sessionCount = 0; lastUpdated = nil
        stoppedSessions = 0; sessionsWithoutAudio = 0; sessionsWithoutResult = 0
        lastPublishedAt = -.infinity; clearTransient()
    }
    func sessionStarted(at _: TimeInterval, service: String = "测试服务") {
        guard enabled else { return }
        if serviceName != "尚未开始", serviceName != service {
            accumulated = [:]; results = [:]; sessionCount = 0; lastUpdated = nil
            stoppedSessions = 0; sessionsWithoutAudio = 0; sessionsWithoutResult = 0
            lastPublishedAt = -.infinity
        }
        serviceName = String(service.prefix(80))
        clearTransient(); sessionCount += 1
    }
    func audioStartAccepted(at time: TimeInterval) {
        guard enabled else { return }; audioAccepted = time
    }
    func cloudStarted(at time: TimeInterval) {
        guard enabled else { return }; cloudBegan = time
    }
    func cloudReady(at time: TimeInterval) {
        guard enabled, let cloudBegan else { return }
        sample(.cloudReady, seconds: time - cloudBegan, at: time, important: true)
    }
    func audioArrived(callbackAt arrival: TimeInterval, handledAt handled: TimeInterval) {
        guard enabled else { return }
        sample(.appDispatch, seconds: handled - arrival, at: handled)
        if let latestAudio { sample(.audioArrivalInterval, seconds: arrival - latestAudio, at: handled) }
        latestAudio = arrival
        if firstAudio == nil {
            firstAudio = arrival
            if let audioAccepted { sample(.handshakeToFirstAudio, seconds: arrival - audioAccepted, at: handled, important: true) }
        }
    }
    func resultReceived(at time: TimeInterval) {
        guard enabled else { return }
        if let latestResult { sample(.resultInterval, seconds: time - latestResult, at: time) }
        latestResult = time
        if let latestAudio { sample(.audioToResult, seconds: time - latestAudio, at: time) }
        if !firstResultRecorded, let firstAudio {
            firstResultRecorded = true
            sample(.firstAudioToFirstResult, seconds: time - firstAudio, at: time, important: true)
        }
    }
    func resultSubmittedToGlasses(at time: TimeInterval) {
        guard enabled, let latestResult else { return }
        sample(.resultToGlassesSubmit, seconds: time - latestResult, at: time)
    }
    func sessionStopped() {
        if enabled {
            stoppedSessions += 1
            if firstAudio == nil { sessionsWithoutAudio += 1 }
            if !firstResultRecorded { sessionsWithoutResult += 1 }
            publish(at: latestResult ?? latestAudio ?? 0)
        }
        clearTransient()
    }

    func snapshot(_ metric: Metric) -> Snapshot { accumulated[metric] ?? Snapshot() }

    var assessment: String {
        guard sessionCount > 0 else { return "开始一次字幕会话后，这里会按阶段判断延迟可能发生在哪里。" }
        var findings: [String] = []
        if stoppedSessions > 0, sessionsWithoutAudio > 0 {
            findings.append("有 \(sessionsWithoutAudio) 次会话未收到有效眼镜音频，优先检查收音启动、连接与后台状态")
        }
        if stoppedSessions > 0, sessionsWithoutResult > 0 {
            findings.append("有 \(sessionsWithoutResult) 次会话没有收到识别结果，检查音频是否进入 ASR、网络与服务配置")
        }
        if snapshot(.handshakeToFirstAudio).maximum >= 2_000 {
            findings.append("字幕收音启动到首包较慢，延迟更可能发生在眼镜收音或眼镜到 App 的链路")
        }
        if snapshot(.appDispatch).maximum >= 200 {
            findings.append("App 主线程排队明显，可能是界面或本机任务繁忙")
        }
        if snapshot(.audioArrivalInterval).maximum >= 750 {
            findings.append("眼镜到 App 的音频到达曾中断，优先检查连接、休眠与系统后台")
        }
        if snapshot(.cloudReady).maximum >= 3_000 {
            findings.append("ASR 建连较慢，可能是网络、DNS、TLS 或服务端负载")
        }
        if snapshot(.firstAudioToFirstResult).maximum >= 3_000 {
            findings.append("首条识别结果较慢；其中也包含说话长度与服务端 VAD/断句等待")
        }
        if snapshot(.resultToGlassesSubmit).maximum >= 700 {
            findings.append("结果进入 App 后到眼镜发送较慢，可能是显示节流或主线程排队")
        }
        return findings.isEmpty ? "当前样本未发现明显的本机排队、音频中断或建连异常。" : findings.joined(separator: "；") + "。"
    }

    var report: String {
        let rows = Metric.allCases.map { metric -> String in
            let value = snapshot(metric)
            return "\(metric.rawValue): n=\(value.count) last=\(value.last)ms avg=\(value.average)ms min=\(value.minimumValue)ms max=\(value.maximum)ms"
        }
        return (["Turbo IO 字幕延迟实验", "service=\(serviceName) sessions=\(sessionCount) stopped=\(stoppedSessions) noAudio=\(sessionsWithoutAudio) noResult=\(sessionsWithoutResult)"] + rows + ["初步判断：\(assessment)",
            "说明：眼镜音频协议没有与手机同钟的采集时间戳，因此首项是启动确认到首包等待，不是麦克风到手机的绝对单向延迟。",
            "说明：流式结果不能与最近一个音频包一一对应，相关指标只用于比较异常会话；首条结果还包含说话与 VAD/断句等待。",
            "不包含音频、字幕正文、密钥、原始序号或设备标识。"
        ]).joined(separator: "\n")
    }

    private func sample(_ metric: Metric, seconds: TimeInterval, at time: TimeInterval, important: Bool = false) {
        guard seconds.isFinite, seconds >= 0 else { return }
        var value = accumulated[metric] ?? Snapshot()
        value.add(Int((seconds * 1_000).rounded()))
        accumulated[metric] = value
        if important || time - lastPublishedAt >= 0.5 { publish(at: time) }
    }
    private func publish(at time: TimeInterval) {
        results = accumulated; lastUpdated = Date(); lastPublishedAt = time
    }
    private func clearTransient() {
        cloudBegan = nil; audioAccepted = nil; firstAudio = nil
        latestAudio = nil; latestResult = nil; firstResultRecorded = false
    }
}
