import Foundation
import RayNeoProtocol
import RayNeoCaptions

/// Long-running display-only subtitle presenter. It never emits business-19
/// type 1/2/4 and therefore cannot create a second glasses audio session.
@MainActor final class LensCaptionPresenter {
    enum Phase { case idle, opening, ready }
    private(set) var phase: Phase = .idle
    private(set) var target: String?
    private(set) var sid: String?
    var onFailure: ((String) -> Void)?
    private let currentDevice: () -> String?
    private let claimDisplay: (Bool) -> Void
    private let send: (String, Data) throws -> Void
    private let uptime: () -> TimeInterval
    private var pendingText: String?
    private var lastSentAt: TimeInterval = -.infinity
    private var deadline: TimeInterval = 0

    init(currentDevice: @escaping () -> String?, claimDisplay: @escaping (Bool) -> Void,
         send: @escaping (String, Data) throws -> Void,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.currentDevice = currentDevice; self.claimDisplay = claimDisplay
        self.send = send; self.uptime = uptime
    }

    @discardableResult func open(on device: String) -> Bool {
        close(notifyGlasses: true)
        guard currentDevice() == device else { return false }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            claimDisplay(true); try send(device, SubtitleDisplayWire.preview(sid: id))
            target = device; sid = id; phase = .opening; deadline = uptime() + 10
            pendingText = "全天智记正在聆听…"
            return true
        } catch {
            claimDisplay(false); reset(); onFailure?("镜片字幕启动失败；全天文字转写会继续。")
            return false
        }
    }

    func receive(device: String, packet: Data) {
        guard device == target, currentDevice() == device, let sid,
              let reply = try? SubtitleDisplayWire.reply(packet), reply.sid == sid else { return }
        if reply.type == 8, phase == .opening {
            guard reply.code == 1 || reply.code == 2 else { fail("眼镜拒绝了镜片字幕显示；全天文字转写会继续。"); return }
            phase = .ready; pump(force: true)
        } else if reply.type == 3 {
            close(notifyGlasses: false)
        }
    }

    func update(_ text: String, final: Bool) {
        guard phase != .idle else { return }
        pendingText = CaptionText.lensWindow(text.isEmpty ? "全天智记正在聆听…" : text, maximumBytes: 384)
        pump(force: final)
    }

    func tick() {
        guard phase != .idle else { return }
        guard currentDevice() == target else { close(notifyGlasses: false); return }
        if phase == .opening, uptime() >= deadline { fail("镜片字幕开启超时；全天文字转写会继续。"); return }
        pump(force: false)
    }

    func transportFailed(device: String, packet: Data, code: Int) {
        guard device == target, let reply = try? SubtitleDisplayWire.reply(packet), reply.sid == sid else { return }
        if reply.type != 3 { fail("镜片字幕命令发送失败（\(code)）；全天文字转写会继续。") }
    }

    func close(notifyGlasses: Bool) {
        if notifyGlasses, let target, let sid, currentDevice() == target {
            try? send(target, SubtitleDisplayWire.stop(sid: sid))
        }
        if phase != .idle { claimDisplay(false) }
        reset()
    }

    private func pump(force: Bool) {
        guard phase == .ready, let target, let sid, let pendingText,
              force || uptime() - lastSentAt >= 0.5 else { return }
        do {
            try send(target, SubtitleDisplayWire.text(pendingText, sid: sid))
            self.pendingText = nil; lastSentAt = uptime()
        } catch { fail("镜片字幕更新失败；全天文字转写会继续。") }
    }

    private func fail(_ message: String) {
        close(notifyGlasses: true); onFailure?(message)
    }
    private func reset() {
        phase = .idle; target = nil; sid = nil; pendingText = nil
        deadline = 0; lastSentAt = -.infinity
    }
}
