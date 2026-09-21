import Foundation
import Combine
import UIKit
import RayNeoProtocol

@MainActor final class SubtitleDisplayRuntime: ObservableObject {
    @Published private(set) var phase: SubtitleDisplaySession.Phase = .idle
    @Published private(set) var status = "准备测试眼镜字幕显示"
    @Published private(set) var expectedText = ""
    @Published private(set) var frames = 0
    @Published private(set) var playing = false
    @Published private(set) var visibleConfirmed = false
    @Published private(set) var events: [String] = []
    private let session: SubtitleDisplaySession
    private let device: () -> String?
    private let available: () -> Bool
    private let supported: () -> Bool
    private let claimDisplay: (Bool) -> Void
    private let uptime: () -> TimeInterval
    private let scheduleTimers: Bool
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var demo: [String] = []
    private var nextFrame = 0
    private var nextFrameAt: TimeInterval = 0
    var occupied: Bool { session.occupied }
    var canOpen: Bool { !occupied && supported() && device() != nil && available() }
    var canPlay: Bool { phase == .ready && !playing && nextFrame < demo.count }
    var canRetryExit: Bool { phase == .uncertain && device() == session.target }
    private var now: TimeInterval { uptime() }

    init(device: @escaping () -> String?, available: @escaping () -> Bool,
         supported: @escaping () -> Bool, claimDisplay: @escaping (Bool) -> Void,
         send: @escaping (String, Data) throws -> Void,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleTimers: Bool = true) {
        self.device = device; self.available = available; self.supported = supported
        self.claimDisplay = claimDisplay; self.uptime = uptime; self.scheduleTimers = scheduleTimers
        session = SubtitleDisplaySession(send: { target, data in
            do { try send(target, data); return true } catch { return false }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop(reason: "App 已进入后台") }
            })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            })
    }
    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    func open(confirmedIdle: Bool) {
        guard !occupied else { return }
        guard confirmedIdle, canOpen, let target = device() else {
            status = "请连接眼镜，并确认已退出录音、提词和其他显示任务"; return
        }
        claimDisplay(true) // Pauses legacy voice standby before claiming the display.
        guard device() == target else {
            claimDisplay(false); status = "眼镜连接已变化，请重新确认连接"; return
        }
        playing = false; nextFrame = 0
        _ = session.begin(target: target, confirmedIdle: true, now: now)
        demo = Self.demoFrames(marker: String((session.sid ?? "test").prefix(4)).uppercased())
        if !session.occupied { claimDisplay(false) }
        refresh()
    }
    func receive(device: String, packet: Data) {
        let wasOpening = session.phase == .opening
        session.receive(from: device, packet: packet, now: now)
        if wasOpening, session.phase == .ready { submitNext() }
        refresh()
    }
    func transportFailed(device: String, packet: Data, code: Int) {
        session.transportFailed(from: device, packet: packet, code: code, now: now); refresh()
    }
    func connectionChanged() {
        session.connectionChanged(currentDevice: device(), now: now); refresh()
    }
    func lostMessages() { stop(reason: "显示回执队列丢包，请重新确认眼镜状态") }
    func play() {
        guard canPlay else { return }
        playing = true; nextFrameAt = now + 1
    }
    private func submitNext() {
        guard nextFrame < demo.count else { playing = false; return }
        if session.show(demo[nextFrame], now: now) { nextFrame += 1; nextFrameAt = now + 1 }
        if nextFrame == demo.count { playing = false }
    }
    func tick() {
        guard session.occupied else { return }
        if session.occupied, device() != session.target {
            session.connectionChanged(currentDevice: device(), now: now)
        }
        session.tick(now: now)
        if playing, session.phase == .ready, now >= nextFrameAt { submitNext() }
        refresh()
    }
    func stop(reason: String = "用户停止") {
        playing = false; session.stop(reason: reason, now: now); refresh()
    }
    func retryExit() {
        guard canRetryExit else { return }
        session.retryStop(now: now); refresh()
    }
    func confirmVisible() { session.confirmVisible(now: now); refresh() }
    func confirmExited() {
        guard session.confirmExited(now: now) else { return }
        claimDisplay(false); refresh()
    }
    private func refresh() {
        phase = session.phase; status = session.note; expectedText = session.text
        frames = session.frames; visibleConfirmed = session.wearerSawText; events = session.events
        if session.phase != .ready { playing = false }
        if session.phase == .idle || session.phase == .uncertain { timer?.invalidate(); timer = nil }
        else if scheduleTimers, timer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    var diagnosticText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (["Turbo IO 字幕显示测试", "版本：\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "阶段：\(phase.rawValue)", "已提交文字帧：\(frames)", "用户确认看到：\(visibleConfirmed)",
            "非预期音频事件：\(session.unexpectedAudio)", "说明：只记录事件元数据，不含密钥、音频或设备标识。"] + events).joined(separator: "\n")
    }
    private static func demoFrames(marker: String) -> [String] {
        let title = "字幕测试 · \(marker)"
        return [title] + ["这", "这是一段", "这是一段测试", "这是一段测试文字。",
            "这是一段测试文字。\n正在", "这是一段测试文字。\n正在逐步更新。",
            "下一句：文字应当更新", "下一句：文字应当更新，而不是反复叠加。",
            "Streaming", "Streaming subtitle", "Streaming subtitle display test.",
            "测试结束。\n请点击手机上的停止并退出。"].map { title + "\n" + $0 }
    }
}
