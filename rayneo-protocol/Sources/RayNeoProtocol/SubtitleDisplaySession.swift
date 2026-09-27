import Foundation

/// Clock-driven, display-only test session. The host serializes calls, owns the
/// authenticated device and supplies transport. No ASR, microphone or audio storage.
public final class SubtitleDisplaySession {
    public enum Phase: String { case idle, opening, ready, stopping, uncertain }
    public private(set) var phase: Phase = .idle
    public private(set) var target: String?
    public private(set) var sid: String?
    public private(set) var note = "准备测试眼镜字幕显示"
    public private(set) var text = ""
    public private(set) var frames = 0
    public private(set) var unexpectedAudio = 0
    public private(set) var wearerSawText = false
    public private(set) var events: [String] = []
    public var occupied: Bool { phase != .idle }
    private let send: (String, Data) -> Bool
    private let makeID: () -> String
    private var began: TimeInterval = 0, deadline: TimeInterval = 0
    private var lastTextAt: TimeInterval?
    public init(send: @escaping (String, Data) -> Bool,
                makeID: @escaping () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }) {
        self.send = send; self.makeID = makeID
    }
    @discardableResult public func begin(target: String, confirmedIdle: Bool, now: TimeInterval) -> Bool {
        guard !occupied, confirmedIdle, !target.isEmpty else { return false }
        let id = makeID()
        guard let packet = try? SubtitleDisplayWire.preview(sid: id) else { return false }
        self.target = target; sid = id; began = now; deadline = now + 10
        text = ""; frames = 0; unexpectedAudio = 0; wearerSawText = false; events = []; lastTextAt = nil
        phase = .opening; note = "正在打开眼镜字幕显示，等待眼镜回应"
        record("提交字幕临时显示设置 type=7", now: now)
        if !send(target, packet), sid == id, phase == .opening || phase == .ready {
            stop(reason: "显示设置提交失败", now: now); return false
        }
        return phase == .opening || phase == .ready
    }
    public func receive(from device: String, packet: Data, now: TimeInterval) {
        guard occupied, device == target else { return }
        guard let reply = try? SubtitleDisplayWire.reply(packet) else {
            stop(reason: "字幕回包格式无法识别", now: now); return
        }
        if reply.type == 4 {
            unexpectedAudio += 1
            record("收到非预期字幕音频事件；未解码、保存或上传", now: now)
            stop(reason: "眼镜回传了非预期音频，结束显示测试", now: now); return
        }
        guard reply.sid == sid else { record("忽略其他会话的 type=\(reply.type) 回包", now: now); return }
        record("收到 type=\(reply.type)，code=\(reply.code.map(String.init) ?? "无")", now: now)
        if reply.type == 8, phase == .opening {
            guard now < deadline else { stop(reason: "眼镜显示回应超时", now: now); return }
            guard reply.code == 1 || reply.code == 2 else {
                stop(reason: "眼镜未接受显示设置（code=\(reply.code.map(String.init) ?? "无效")）", now: now); return
            }
            phase = .ready; note = "眼镜已回应显示设置，请核对镜片文字"
        } else if reply.type == 3 {
            if phase == .opening || phase == .ready { stop(reason: "收到眼镜结束消息", now: now) }
            // Direction/semantics of type 3 are not sufficient proof of physical exit.
            note = "收到退出相关消息，请确认眼镜已回首页"
        }
    }
    @discardableResult public func show(_ value: String, now: TimeInterval) -> Bool {
        tick(now: now)
        guard phase == .ready, let sid, let target,
              lastTextAt.map({ now - $0 >= 0.5 }) ?? true, frames < 80,
              let packet = try? SubtitleDisplayWire.text(value, sid: sid) else { return false }
        guard send(target, packet) else { stop(reason: "字幕文字提交失败", now: now); return false }
        guard self.sid == sid, phase == .ready else { return false }
        text = value; frames += 1; lastTextAt = now
        note = "已提交第 \(frames) 帧，请以镜片显示为准"
        record("提交文字 type=5，第 \(frames) 帧，\(value.utf8.count) bytes", now: now)
        return true
    }
    public func tick(now: TimeInterval) {
        if phase == .opening, now >= deadline { stop(reason: "10 秒未收到眼镜显示回应", now: now) }
        else if phase == .ready, now - began >= 60 { stop(reason: "本轮 60 秒显示测试结束", now: now) }
        else if phase == .stopping, now >= deadline {
            phase = .uncertain; note = "退出尚未确认，请在眼镜退出后点击确认"
            record("退出等待超时，保留占用直到用户确认", now: now)
        }
    }
    public func stop(reason: String = "用户停止", now: TimeInterval) {
        guard phase == .opening || phase == .ready else { return }
        submitStop(reason: reason, now: now)
    }
    public func retryStop(now: TimeInterval) {
        guard phase == .uncertain else { return }
        submitStop(reason: "用户重试退出", now: now)
    }
    private func submitStop(reason: String, now: TimeInterval) {
        guard let sid, let target else { return }
        phase = .stopping; deadline = now + 8; note = reason + "；已请求退出，请确认眼镜回首页"
        record(reason + "；提交退出 type=3", now: now)
        guard let packet = try? SubtitleDisplayWire.stop(sid: sid), send(target, packet) else {
            phase = .uncertain; note = "退出提交失败，请在眼镜退出后点击确认"; return
        }
    }
    public func connectionChanged(currentDevice: String?, now: TimeInterval) {
        guard occupied, phase != .uncertain, currentDevice != target else { return }
        phase = .uncertain; note = "眼镜连接已变化，请确认原眼镜已退出字幕"
        record("连接中断或设备变化；未向其他设备发送退出", now: now)
    }
    public func transportFailed(from device: String, packet: Data, code: Int, now: TimeInterval) {
        guard occupied, device == target, let reply = try? SubtitleDisplayWire.reply(packet), reply.sid == sid else { return }
        record("SDK 异步发送失败 type=\(reply.type)，code=\(code)", now: now)
        if reply.type == 3 {
            phase = .uncertain; note = "眼镜退出发送失败，请在眼镜退出后点击确认"
        } else { stop(reason: "眼镜显示命令发送失败", now: now) }
    }
    public func confirmVisible(now: TimeInterval) {
        guard phase == .ready, frames > 0 else { return }
        wearerSawText = true; record("用户确认镜片看到了本轮测试文字", now: now)
    }
    @discardableResult public func confirmExited(now: TimeInterval) -> Bool {
        guard phase == .stopping || phase == .uncertain else { return false }
        record("用户确认眼镜已退出；非协议回执", now: now)
        phase = .idle; target = nil; sid = nil
        note = "本轮已结束；眼镜退出由你确认"; return true
    }
    private func record(_ value: String, now: TimeInterval) {
        events.append(String(format: "+%.1fs ", max(0, now - began)) + value)
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }
}
