import Foundation
import Combine
import RayNeoDisplay
import RayNeoProtocol
import UIKit
import CryptoKit

@MainActor final class CompanionDeviceFeatures: ObservableObject {
    @Published private(set) var status = "连接后可使用眼镜功能；未自动开始采音"
    @Published private(set) var recordingStatus = "未启用眼镜录音接收"
    @Published private(set) var recordingID: String?
    @Published private(set) var recordingBytes = 0
    @Published private(set) var acceptsEyeRecording = false
    @Published private(set) var todoStatus = "尚未同步"
    @Published private(set) var battery: Int?
    @Published private(set) var brightness: Int?
    @Published private(set) var settings: [String: Any] = [:]
    @Published private(set) var completedRecording: URL?
    @Published private(set) var recoveryEntries: [GlassesRecordingInbox.Entry] = []
    @Published private(set) var recoveryBusy = false
    @Published private(set) var recoveryStatus = "仅扫描本机，不访问眼镜。"
    @Published var error: String?
    @Published private(set) var subtitleShortcutStatus = "先读取眼镜设置，再配置双击字幕"
    private var crownReadAt = Date.distantPast
    var doubleTapIsSubtitle: Bool {
        let crown = settings["crownConfig"] as? [String: Any] ?? settings["crown_config"] as? [String: Any]
        return DeviceBusinessWire.integer(crown ?? [:], "double") == 4
    }
    let voice: CompanionVoiceRuntime
    private weak var store: CompanionStore?
    private let inbox: GlassesRecordingInbox
    private let io = DispatchQueue(label: "companion.recording.inbox", qos: .utility)
    private let writeSlots = DispatchSemaphore(value:64)
    private var failedRecordings = Set<String>()
    private var captureDevice: String?
    private var recordTimeRaw: Int64?
    private var finishing = Set<String>()
    private var finalizationInFlight = false
    private var pendingSettings: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    var canControl: Bool { voice.ready && !voice.subtitleOwnsDisplay && !recoveryBusy && store?.alwaysOn.occupied != true && !["recording", "processing", "displaying"].contains(voice.phase) }
    init(voice: CompanionVoiceRuntime, store: CompanionStore, root: URL) {
        self.voice = voice; self.store = store; inbox = GlassesRecordingInbox(root: root)
        voice.onBusiness = { [weak self] in self?.receive(device: $0, business: $1, data: $2) }
        voice.onBusinessLoss = { [weak self] in self?.lostMessages(); self?.store?.alwaysOn.lostMessages(); self?.store?.subtitleDisplay.lostMessages() }
        voice.onSubtitleLoss = { [weak self] in self?.store?.realtimeSubtitles.inputLost() }
        voice.onSubtitleSendError = { [weak self] in
            self?.store?.subtitleDisplay.transportFailed(device: $0, packet: $1, code: $2)
            self?.store?.realtimeSubtitles.transportFailed(device: $0, packet: $1, code: $2, messageID: $3)
            self?.store?.alwaysOn.displayTransportFailed(device: $0, packet: $1, code: $2)
        }
        voice.onTeleprompterSendError = { [weak self] device, packet, code, _ in
            self?.teleprompterTransportFailed(device: device, packet: packet, code: code)
        }
        voice.onFileShareEvent = { [weak self] device, task, stage, progress, name, failure in
            self?.teleprompterFileEvent(device: device, task: task, stage: stage,
                                       progress: progress, fileName: name, failure: failure)
        }
        voice.onSubtitleEnvelope = { [weak self] in self?.store?.realtimeSubtitles.receive(device: $0, packet: $1, arrival: $2) }
        // One automatic weather owner. Legacy Weatherstack stays manual to avoid overwrites.
        voice.onRuntimeRefresh = { [weak self] in self?.store?.qweather.tick() }
        voice.featureIsBusy = { [weak self] in self?.recordingID != nil || self?.teleprompterID != nil || self?.store?.alwaysOn.occupied == true || self?.store?.speechPrompter.active == true }
        voice.onConnectionChange = { [weak self] device in
            guard let self else { return }
            self.store?.notifications.connectionChanged()
            self.store?.headControlTest.connectionChanged()
            self.store?.alwaysOn.connectionChanged()
            self.store?.subtitleDisplay.connectionChanged()
            self.store?.realtimeSubtitles.connectionChanged()
            self.pendingSettings.removeAll(); self.settings = [:]; self.battery = nil; self.brightness = nil
            self.crownReadAt = .distantPast
            if self.recordingID != nil { self.recordingStatus = device == self.captureDevice ? "连接恢复；等待同一录音状态/数据，不自动宣布补传完成" : "连接中断；原始录音保留，等待同一眼镜恢复" }
            if self.teleprompterID != nil, device != self.teleprompterDevice {
                self.teleprompterTransfer.cancel(); self.teleprompterTransferGeneration = UUID()
                self.teleprompterTransferTask = nil
                self.teleprompterPrepared = false
                self.teleprompterStarted = false
                self.teleprompterStatus = "提词连接中断；停止自动操作，请恢复连接后退出并重新准备"
                self.onTeleprompterFailure?(self.teleprompterStatus)
            }
            if device != nil, self.store?.realtimeSubtitles.shortcutEnabled == true {
                self.subtitleShortcutStatus = "永久双击字幕已开启，正在核对眼镜快捷键"
                // Wait for the authenticated connection callback to unwind before asking for
                // the complete settings object. Never reconstruct or overwrite unknown fields.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.voice.deviceID == device,
                          self.store?.realtimeSubtitles.shortcutEnabled == true else { return }
                    self.refreshSettings()
                }
            }
        }
        for (name, foreground) in [(UIApplication.didEnterBackgroundNotification,false),(UIApplication.didBecomeActiveNotification,true)] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingID != nil, self.voice.deviceID == self.captureDevice else { return }
                    self.perform { try self.send(14,14,["isAppForeground":foreground]) }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func prepare() { voice.prepare(); voice.refresh() }
    private func send(_ business: UInt8, _ type: UInt32, _ json: [String: Any]) throws {
        guard voice.deviceID != nil else { throw DeviceFeatureError.disconnected }
        try voice.sendBusiness(business, payload: DeviceBusinessWire.encode(type: type, json: json))
    }
    func perform(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "操作失败；未确认眼镜完成。" }
    }
    func enableEyeRecording(_ enabled: Bool) {
        guard recordingID == nil else { error = "请先停止录音并等待文件接收结束。"; return }
        acceptsEyeRecording = enabled
        recordingStatus = enabled ? "已允许接收：请在眼镜开始录音；只保存在本机" : "未启用眼镜录音接收"
    }
    func startRecording() {
        perform {
            guard canControl, recordingID == nil, teleprompterID == nil,
                  store?.speechPrompter.active != true, let device = voice.deviceID else { throw DeviceFeatureError.busy }
            // Voice standby is explicitly suspended so an unsolicited wake cannot steal the microphone.
            if voice.enabled { voice.stop() }
            acceptsEyeRecording = true
            let id = UUID().uuidString
            captureDevice = device; recordingID = id; recordingBytes = 0; completedRecording = nil; recordTimeRaw = nil
            recordingStatus = "准备本机接收目录"
            io.async { [weak self, inbox] in
                do {
                    try inbox.begin(device: device, id: id)
                    DispatchQueue.main.async {
                        guard let self, self.recordingID == id, self.voice.deviceID == device else { return }
                        self.perform {
                            try self.send(14,14,["isAppForeground": true])
                            try self.send(14,1,["uuid":id,"action":1,"code":1])
                            self.recordingStatus = "已请求开始，等待眼镜回应"
                        }
                    }
                } catch { DispatchQueue.main.async { self?.error = "接收目录创建失败，未请求眼镜录音。"; self?.recordingID = nil } }
            }
        }
    }
    func recordingControl(_ type: UInt32) {
        perform {
            guard let id = recordingID, voice.deviceID == captureDevice, [4,8,9,11].contains(type) else { throw DeviceFeatureError.noSession }
            var body: [String: Any] = ["uuid": id, "action": type == 11 ? 2 : 1, "code": type == 4 ? 2 : 1]
            // Preserve a reported raw time; never invent an epoch/elapsed-time conversion.
            if type == 9, let time = recordTimeRaw { body["time"] = time }
            try send(14,type,body)
            recordingStatus = type == 4 ? "已请求停止，仍等待尾部音频和完成消息" : "控制已提交，等待眼镜回应"
        }
    }
    func receive(device: String, business: UInt8, data: Data) {
        guard voice.deviceID == device else { return }
        if business == 20, teleprompterID != nil, teleprompterDevice == device {
            do {
                let metadata = try BusinessEnvelopeMetadata.inspect(data)
                if metadata.messageType == 9 {
                    // The official native plugin bypasses JSON entirely for
                    // teleprompter audioData and reads AssistantMsg.data.
                    guard teleprompterStarted, teleprompterScrollMode == 1 else { return }
                    guard let audio = try BusinessEnvelopeMetadata.teleprompterAudio(data) else {
                        throw DeviceFeatureError.invalidPacket
                    }
                    onTeleprompterAudio?(audio, nil)
                    return
                }
            } catch {
                teleprompterFailed("提词音频协议无效；已停止自动跟随，保留当前稿件位置。")
                return
            }
        }
        if business == 19 {
            store?.alwaysOn.receive(device: device, business: business, packet: data)
            store?.subtitleDisplay.receive(device: device, packet: data)
            return
        }
        if business == 13 || business == 15 { store?.alwaysOn.receive(device: device, business: business, packet: data) }
        do {
            let wire = try DeviceBusinessWire(data)
            switch business {
            case 14: try recording(device,wire)
            case 22: try todo(device,wire)
            case 15:
                store?.qweather.receive(device:device,wire:wire)
                launcher(wire)
            case 20: try teleprompterReceive(device,wire)
            case 21:
                store?.notifications.receive(device: device, wire: wire)
                store?.headControlTest.receive(device: device, wire: wire)
            default: break
            }
        } catch {
            self.error = "收到未识别或不匹配的业务数据，未当成成功。"
            if business == 14 { lostMessages() }
            if business == 20, teleprompterID != nil, teleprompterDevice == device {
                teleprompterFailed("收到无效提词控制；保留当前位置，请结束本轮后重试。")
            }
        }
    }
    private func recording(_ device: String, _ wire: DeviceBusinessWire) throws {
        let j = wire.json, type = wire.type
        if type == 12 { recordingStatus = "收到同步列表；本版不自动导入或清理离线积压"; return }
        guard let id = DeviceBusinessWire.identifier(j,"uuid") else { return }
        if type == 3, finishing.contains(id), recordingID != id, captureDevice == device {
            error = "已封装录音仍收到迟到数据；请保留副本并复核，不能承诺完整。"
            io.async { [inbox] in inbox.invalidate(device:device,id:id) }
            return
        }
        let action = DeviceBusinessWire.integer(j,"action"), code = DeviceBusinessWire.integer(j,"code")
        if type == 1, action == 1 {
            guard acceptsEyeRecording, teleprompterID == nil, recordingID == nil || (recordingID == id && captureDevice == device), canControl else { return }
            if voice.enabled { voice.stop() }
            recordingID = id; captureDevice = device; recordingBytes = 0; completedRecording = nil
            io.async { [weak self, inbox] in
                do {
                    try inbox.begin(device: device,id: id)
                    DispatchQueue.main.async {
                        guard let self, self.recordingID == id, self.voice.deviceID == device else { return }
                        self.perform { try self.send(14,1,["uuid":id,"action":2,"code":1]); self.recordingStatus = "已接受眼镜录音，等待数据" }
                    }
                } catch { DispatchQueue.main.async { self?.error = "无法准备眼镜录音的本机存储。" } }
            }
            return
        }
        guard recordingID == id, captureDevice == device else { return }
        if let time = DeviceBusinessWire.integer(j,"time") { recordTimeRaw = time }
        if type == 1, action == 2 {
            if code == 1 { recordingStatus = "眼镜已确认开始录音" }
            else { recordingStatus = "眼镜拒绝开始，code=\(code ?? -1)；未自动绕过隐私/冲突"; recordingID = nil }
        } else if type == 3 {
            guard let offset = DeviceBusinessWire.integer(j,"offset"), offset >= 0,
                  offset <= GlassesRecordingInbox.limit, !wire.bytes.isEmpty else { throw DeviceFeatureError.invalidPacket }
            guard writeSlots.wait(timeout:.now()) == .success else { lostMessages(); return }
            io.async { [weak self, inbox, writeSlots] in
                defer { writeSlots.signal() }
                do { let count = try inbox.append(device:device,id:id,offset:Int(offset),data:wire.bytes)
                    DispatchQueue.main.async { self?.recordingBytes = count; self?.recordingStatus = "正在接收并保存原始音频" }
                } catch { inbox.invalidate(device:device,id:id); DispatchQueue.main.async { self?.error = "音频写入或完整性检查失败；原件保留，不能标完整。" } }
            }
        } else if type == 6, DeviceBusinessWire.boolean(j,"completed") == true, !finishing.contains(id) {
            // Persist the observed completion before queued finalization, so a restart cannot invent or lose it.
            io.async { [inbox] in
                do { try inbox.recordCompletion(device:device,id:id) }
                catch { inbox.invalidate(device:device,id:id) }
            }
            finishing.insert(id); recordingStatus = "眼镜已报告完成，核对接收覆盖并封装"
            // Small grace for callbacks delivered after completion. Late data is never silently merged into a published file.
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in self?.finishRecording(device:device,id:id) }
        } else if type == 4 {
            if action == 1 { try send(14,4,["uuid":id,"action":2,"code":code ?? 1]) }
            recordingStatus = "停止事件已收到，等待音频完成"
        } else if type == 11 {
            if action == 1 { try send(14,11,["uuid":id,"action":2,"code":1]) }
            let time = DeviceBusinessWire.integer(j,"time") ?? 0
            io.async { [inbox] in try? inbox.mark(device:device,id:id,time:time) }
        } else if type == 8 || type == 9 {
            if action == 1 { try send(14,type,["uuid":id,"action":2,"code":1]) }
            recordingStatus = code == 1 ? (type == 8 ? "眼镜已暂停" : "眼镜已恢复") : "控制回应 code=\(code ?? -1)"
        } else if type == 5 { recordingStatus = "收到同一录音重连状态；继续按 offset 校验" }
    }
    private func finishRecording(device: String, id: String) {
        guard !finalizationInFlight else { return }
        finalizationInFlight = true
        io.async { [weak self, inbox] in
            do {
                _ = try inbox.finish(device:device,id:id)
                let output = try inbox.decodedDerivative(device:device,id:id)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finalizationInFlight = false
                    self.completedRecording = output; self.recordingID = nil
                    self.recordingStatus = "接收覆盖和逐包解码通过；WAV 待归档，原始音频/Ogg 保留。不代表无线原音无损。"
                    // Archive copy + checksum, not ASR or upload. Ogg structure is not proof of acoustic completeness.
                    Task { await self.archiveReceivedRecording() }
                }
            } catch {
                DispatchQueue.main.async { self?.finalizationInFlight = false; self?.recordingStatus = "未能完成封装；原始字节和覆盖记录已保留"; self?.error = "录音未通过完整性检查，不标为完整音频。" }
            }
        }
    }
    private func lostMessages() {
        store?.notifications.lostMessages()
        if teleprompterID != nil {
            teleprompterFailed("提词接收队列溢出；已停止自动跟随，保留当前稿件位置。")
        }
        if let id = recordingID, let device = captureDevice, failedRecordings.insert(id).inserted { io.async { [inbox] in inbox.invalidate(device:device,id:id) } }
        error = "业务接收队列溢出或录音格式不匹配；本次录音不可标完整。"
    }
    func archiveReceivedRecording() async {
        guard let file = completedRecording, let store else { return }
        let imported = await store.archive.importFile(file,title:"眼镜录音 " + Date().formatted(date:.abbreviated,time:.shortened))
        recordingStatus = imported ? "WAV 已校验归档；原始音频/Ogg 保留，未转写或上传" : "WAV 已保存，但归档未成功；可重试归档或分享文件"
    }
    func retryRecordingFinish() {
        guard let id = recordingID, let device = captureDevice, finishing.contains(id) else { error = "尚未收到眼镜完成消息，不能强行当作完成。"; return }
        finishRecording(device:device,id:id)
    }
    func loadRecoveryEntries() async {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { recoveryStatus = "当前有接收任务，请结束后再扫描。"; return }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let catalog: GlassesRecordingInbox.Catalog = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.catalog() }) }
            }
            recoveryEntries = catalog.entries
            recoveryStatus = "本机 \(catalog.entries.count) 条；\(catalog.unreadable) 个无法读取的目录保留原位。扫描不等于完整性通过。"
        } catch { recoveryStatus = "本机接收目录无法读取；未清空、重建或删除。" }
    }
    func recoverRecording(_ entryID: String) async {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { return }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let file: URL = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.recoverDecoded(entryID) }) }
            }
            guard let store else { return }
            let imported = await store.archive.importFile(file,title:"恢复的眼镜录音")
            recoveryStatus = imported ? "已重新核对、解码并归档；未转写、上传或删除原件。" : "WAV 已恢复，归档暂未成功；原始文件保留，可重试。"
        } catch { recoveryStatus = "未通过恢复校验或本构建不支持解码；原件保留，不能标完整。" }
    }
    func recoveryRawFile(_ entryID: String) async -> URL? {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { return nil }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.exportRawCopy(entryID) }) }
            }
            return url
        } catch { recoveryStatus = "原始文件不可读取，未生成分享入口。"; return nil }
    }
    func syncTodos(pendingOnly: Bool = false) {
        perform {
            guard canControl, let device = voice.deviceID, let store else { throw DeviceFeatureError.disconnected }
            let rows = try store.todoCandidates(device: device, pendingOnly: pendingOnly)
            guard rows.count <= 100 else { throw DeviceFeatureError.storageLimit }
            for row in rows { try sendTodo(row, device:device) }
            todoStatus = "已提交 \(rows.count) 条待办；等待眼镜状态/操作回执，不代表镜片已显示"
        }
    }
    func localTodoChanged(_ row: LocalTodo) {
        guard canControl, row.archivedAt == nil, row.wireDeviceID == voice.deviceID,
              row.wireID != nil, row.delivery?.conflict == nil else { return }
        perform { guard let device = voice.deviceID else { throw DeviceFeatureError.disconnected }; try sendTodo(row,device:device) }
    }
    private func sendTodo(_ row: LocalTodo, device: String) throws {
        guard let store else { throw DeviceFeatureError.noSession }
        let current = try store.prepareTodoSubmission(row.id, device: device)
        guard let id = current.wireID, let revision = current.delivery?.revision else { throw TodoDeliveryError.missing }
        let seconds = Int64(Date().timeIntervalSince1970)
        let body: [String:Any] = ["eventType":1,"eventID":id,"createTime":Int64(current.createdAt.timeIntervalSince1970),
            "title":current.title,"isImportant":current.important ?? false,"status":current.completed ? 1 : 0,"lastModifiedTime":seconds]
        try send(22,2,body)
        store.markTodoSubmitted(row.id, device: device, revision: revision)
    }
    private func todo(_ device: String, _ wire: DeviceBusinessWire) throws {
        if wire.type == 14 { todoStatus = "眼镜操作回执：成功 \(DeviceBusinessWire.integer(wire.json,"successCount") ?? 0)；不作为逐项镜片验收"; return }
        guard wire.type == 4 || wire.type == 10 else { return }
        let data = try JSONSerialization.data(withJSONObject:wire.json)
        let message = try TodoJSONCodec().decodeGlassesMessage(type:UInt16(wire.type),payload:data)
        var changes = 0
        switch message {
        case .status(let s): changes += store?.applyGlassesTodo(device:device,id:s.eventID,status:s.statusRaw,important:s.isImportant.value) == true ? 1 : 0
        case .batch(let b):
            for entry in b.eventList.value ?? [] { if case .todo(let s) = entry { changes += store?.applyGlassesTodo(device:device,id:s.eventID,status:s.statusRaw,important:s.isImportant.value) == true ? 1 : 0 } }
        default: break
        }
        todoStatus = "眼镜状态已应用 \(changes) 项；离线修改冲突请查看待发送列表，未知 ID 不导入"
    }
    func refreshSettings() {
        perform {
            try voice.sendBusiness(15,payload:LauncherControlPrototype.encode(.requestGeneralStatus))
            try send(15,4,["cmd":"request_general_settings","payload":["value":0,"mode":0,"data":""]])
            status = "已查询，等待眼镜状态"
        }
    }
    func setBrightness(_ value: Int) { command(type:2,cmd:"brightness_change",value:value,allowed:7...8) }
    func setHeadControl(_ enabled: Bool, mode: Int) {
        guard [0,1].contains(mode) else { return }; command(type:5,cmd:"head_gestures",value:enabled ? 1:0,mode:mode)
    }
    func setSleep(_ seconds: Int) { guard [15,25].contains(seconds) else { return }; command(type:5,cmd:"auto_lock_time",value:seconds) }
    func setDoubleTapTodo(_ todo: Bool) {
        guard let crown = settings["crownConfig"] as? [String:Any] ?? settings["crown_config"] as? [String:Any],
              let long = DeviceBusinessWire.integer(crown,"longPress") else { error = "请先读取完整旋钮设置，避免覆盖原长按配置。"; return }
        perform { let body = try JSONSerialization.data(withJSONObject:["double":todo ? 8:0,"longPress":long]); try submitCommand(type:5,cmd:"crown_config",value:0,mode:0,data:String(decoding:body,as:UTF8.self)) }
    }
    func setDoubleTapSubtitles(_ enabled: Bool) {
        guard let device = voice.deviceID, Date().timeIntervalSince(crownReadAt) < 60,
              let crown = settings["crownConfig"] as? [String:Any] ?? settings["crown_config"] as? [String:Any],
              let original = DeviceBusinessWire.integer(crown, "double") else {
            error = "请先读取眼镜完整旋钮设置（60 秒内有效），保留其他按键配置。"; return
        }
        let scope = SHA256.hash(data: Data(device.utf8)).map { String(format: "%02x", $0) }.joined()
        let backup = "companion.realtimeSubtitles.previousDoubleTap." + scope
        let old = (UserDefaults.standard.object(forKey: backup) as? NSNumber)?.intValue
        guard enabled || old != nil else { error = "没有本 App 保存的旧快捷键；请在设备设置中自行选择。"; return }
        perform {
            let changed = try SubtitleShortcut.replacingDouble(in: crown, with: enabled ? 4 : old!)
            let body = try JSONSerialization.data(withJSONObject: changed)
            if enabled, original != 4, old == nil { UserDefaults.standard.set(Int(original), forKey: backup) }
            try submitCommand(type: 5, cmd: "crown_config", value: 0, mode: 0, data: String(decoding: body, as: UTF8.self))
            crownReadAt = .distantPast
            subtitleShortcutStatus = "设置已提交，请再次读取设置确认；不会覆盖长按或其他字段。"
        }
    }
    func setDisplay(height: Int? = nil, distance: Int? = nil) {
        guard let config = settings["displayConfig"] as? [String:Any] ?? settings["display_config"] as? [String:Any],
              let oldHeight = DeviceBusinessWire.integer(config,"height"), let oldDistance = DeviceBusinessWire.integer(config,"distance"),
              height == nil || [1,3,5].contains(height!), distance == nil || [1,2].contains(distance!) else {
            error = "请先读取显示配置；只支持已有证据的档位，未覆盖其他参数。"; return
        }
        perform {
            let data = try JSONSerialization.data(withJSONObject:["height":height.map(Int64.init) ?? oldHeight,"distance":distance.map(Int64.init) ?? oldDistance])
            try submitCommand(type:5,cmd:"display_config",value:0,mode:0,data:String(decoding:data,as:UTF8.self))
        }
    }
    func sendWeatherstack(_ snapshot: WeatherstackSnapshot, icon: Int) {
        perform { try submitWeatherstack(snapshot, icon: icon) }
    }
    func submitWeatherstack(_ snapshot: WeatherstackSnapshot, icon: Int) throws {
        guard snapshot.canSend(at:Date()) else { throw WeatherstackError.stale }
        guard (0...999).contains(icon) else { throw WeatherstackError.icon }
        try submitWeather(location:snapshot.city,temperature:snapshot.lensTemperature,icon:icon,description:snapshot.description)
    }
    func sendWeather(location: String, temperature: Int, icon: Int, description: String, current: Bool = true) {
        perform { try submitWeather(location:location,temperature:temperature,icon:icon,description:description,current:current) }
    }
    private func submitWeather(location: String, temperature: Int, icon: Int, description: String, current: Bool = true) throws {
            guard canControl, !location.isEmpty, location.utf8.count <= 80, (-80...60).contains(temperature), (0...999).contains(icon) else { throw DeviceFeatureError.invalidPacket }
            let update = SelectedCityWeatherRawUpdate(items:[CityWeatherRawItem(location:location,locationID:"companion-custom",temperatureRaw:Int64(temperature),iconRaw:Int64(icon),descriptionRaw:description,temperatureRangeRaw:"",hourly:[])],timestampRaw:String(Int64(Date().timeIntervalSince1970)))
            let msg = try current ? WeatherJSONCodec().encodeCurrentWeatherUpdate(CurrentWeatherRawUpdate(location:location,temperatureRaw:Int64(temperature),iconRaw:Int64(icon),timestampRaw:update.timestampRaw)) : CityWeatherJSONCodec().encodeUpdate(update)
            try voice.sendBusiness(15,payload:DeviceBusinessWire.encode(type:UInt32(msg.type),json:JSONSerialization.jsonObject(with:msg.payload) as! [String:Any]))
            pendingSettings[current ? "current_weather_update" : "weather_update"] = Date(); status = "自定义天气数据已提交；不更改看板组件布局，等待回执"
    }
    private func command(type: UInt32, cmd: String, value: Int, mode: Int = 0, allowed: ClosedRange<Int>? = nil) {
        perform { if let allowed, !allowed.contains(value) { throw DeviceFeatureError.invalidPacket }; try submitCommand(type:type,cmd:cmd,value:value,mode:mode,data:"") }
    }
    private func submitCommand(type: UInt32, cmd: String, value: Int, mode: Int, data: String) throws {
        guard canControl else { throw DeviceFeatureError.busy }
        if let since = pendingSettings[cmd], Date().timeIntervalSince(since) < 8 { throw DeviceFeatureError.busy }
        try send(15,type,["cmd":cmd,"payload":["value":value,"mode":mode,"data":data]])
        pendingSettings[cmd] = Date(); status = "设置已提交，等待眼镜回报；不提前改显示值"
    }
    private func launcher(_ wire: DeviceBusinessWire) {
        let j = wire.json
        if wire.type == 1 {
            let state = j["generalStatus"] as? [String:Any] ?? j
            if let n = DeviceBusinessWire.integer(state,"battery") { battery = Int(n) }
            if let n = DeviceBusinessWire.integer(state,"brightness") { brightness = Int(n) }
        }
        if wire.type == 4 {
            settings = j["generalSettings"] as? [String:Any] ?? j; status = "眼镜通用设置已收到"
            crownReadAt = Date()
            if store?.realtimeSubtitles.shortcutEnabled == true, !doubleTapIsSubtitle {
                subtitleShortcutStatus = "检测到双击映射丢失，正在自动恢复字幕"
                setDoubleTapSubtitles(true)
            } else {
                subtitleShortcutStatus = doubleTapIsSubtitle ? "眼镜回读：双击已设置为字幕（永久）" : "眼镜回读：双击当前不是字幕"
            }
        }
        guard let cmd = j["cmd"] as? String, let p = j["payload"] as? [String:Any] else { return }
        if wire.type == 3, cmd == "brightness_change", let n = DeviceBusinessWire.integer(p,"value") { brightness = Int(n) }
        if [3,6,17,19].contains(wire.type) {
            if wire.type == 6, let body = p["data"] as? String, let bytes = body.data(using:.utf8),
               let config = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
               let key = ["display_config":"displayConfig","crown_config":"crownConfig","privacy_config":"privacyConfig"][cmd] {
                settings[key] = config
                if cmd == "crown_config" {
                    subtitleShortcutStatus = doubleTapIsSubtitle ? "眼镜已确认：双击永久设为字幕" : "眼镜回报：双击不是字幕"
                }
            }
            pendingSettings.removeValue(forKey:cmd)
            status = "眼镜回报 \(cmd.prefix(45))：\(DeviceBusinessWire.integer(p,"value") ?? -1)（未验证镜片效果）"
        }
    }

    // Teleprompter state/transport is implemented in the dedicated extension below.
    @Published private(set) var teleprompterStatus = "尚未发送稿件"
    @Published private(set) var teleprompterID: String?
    @Published private(set) var teleprompterOffset: Int64 = 0
    @Published private(set) var teleprompterStarted = false
    @Published private(set) var teleprompterTransferProgress: Int?
    @Published private(set) var teleprompterTransferError: String?
    var onTeleprompterProgress: ((TeleprompterPositionObserved) -> Void)?
    var onTeleprompterPositionUnavailable: (() -> Void)?
    var onTeleprompterControl: ((UInt32) -> Void)?
    var onTeleprompterAudio: ((Data, Int?) -> Void)?
    var onTeleprompterFailure: ((String) -> Void)?
    var teleprompterFile: URL?
    var teleprompterDevice: String?
    var teleprompterPrepared = false
    var teleprompterSentFile = false
    var teleprompterTransferTask: String?
    private var teleprompterScrollMode = 2
    private var teleprompterBoundaries = Set<Int>()
    private var teleprompterDocument: TeleprompterNativeDocument?
    private var teleprompterTransfer = TeleprompterTransferPolicy()
    private var teleprompterTransferGeneration = UUID()
}

extension CompanionDeviceFeatures {
    func prepareTeleprompter(_ text: String, speed: Int, scrollMode: Int = 2, initialOffset: Int = 0) {
        perform {
            guard canControl, recordingID == nil, teleprompterID == nil, let device = voice.deviceID else { throw DeviceFeatureError.busy }
            guard scrollMode != 2 || store?.speechPrompter.active != true else { throw DeviceFeatureError.invalidPacket }
            let document = try TeleprompterNativeDocument(text: text, speed: speed,
                                                        scrollMode: scrollMode, initialOffset: initialOffset)
            if voice.enabled { voice.stop() }
            let did = UUID().uuidString.lowercased()
            let dir = inbox.root.deletingLastPathComponent().appendingPathComponent("TeleprompterOutboxV1")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            guard try FileManager.default.contentsOfDirectory(atPath:dir.path).count < 100 else { throw DeviceFeatureError.storageLimit }
            let url = try TeleprompterNativeDocument.fileURL(directory: dir, did: did)
            try document.data.write(to:url,options:[.withoutOverwriting,.completeFileProtectionUntilFirstUserAuthentication])
            teleprompterID = did; teleprompterDevice = device; teleprompterFile = url
            teleprompterOffset = Int64(initialOffset); teleprompterPrepared = false; teleprompterSentFile = false
            teleprompterStarted = false; teleprompterScrollMode = scrollMode
            teleprompterTransfer = TeleprompterTransferPolicy(); teleprompterTransferProgress = nil
            teleprompterTransferError = nil
            teleprompterTransferGeneration = UUID(); let transferGeneration = teleprompterTransferGeneration
            teleprompterBoundaries = document.boundaries; teleprompterDocument = document
            // Optional layout fields intentionally omitted: never guess pixel/gear defaults.
            do {
                try send(20,2,document.command(type: 2, did: did))
            } catch {
                teleprompterFailed("提词准备发送失败，尚未开始跟随。")
                discardTeleprompterFile()
                throw error
            }
            teleprompterStatus = "已请求准备稿件，等待眼镜收稿回应"
            DispatchQueue.main.asyncAfter(deadline:.now()+30) { [weak self] in
                guard let self, self.teleprompterID == did,
                      self.teleprompterTransferGeneration == transferGeneration,
                      !self.teleprompterTransfer.fileRequestedBool else { return }
                self.teleprompterFailed("眼镜未在 30 秒内允许传稿，请退出本轮后重试。")
            }
        }
    }
    func teleprompterControl(_ type: UInt32, speed: Int = 120) {
        perform {
            guard let did = teleprompterID, teleprompterDevice == voice.deviceID,
                  type == 6 || teleprompterPrepared else { throw DeviceFeatureError.noSession }
            guard [3,4,5,6,7].contains(type) else { throw DeviceFeatureError.invalidPacket }
            var body: [String:Any] = ["action":1,"did":did]
            if type == 3 {
                guard let document = teleprompterDocument else { throw DeviceFeatureError.noSession }
                body = try document.command(type: 3, did: did)
            }
            if type == 4 { body["offset"] = teleprompterOffset; body["code"] = 1; body["isCompleted"] = false }
            if type == 7 { guard (60...240).contains(speed) else { throw DeviceFeatureError.invalidPacket }; body["scroll"] = teleprompterScrollMode; body["speed"] = speed }
            try send(20,type,body)
            if type == 6 {
                teleprompterTransfer.cancel(); teleprompterTransferGeneration = UUID()
                if let task = teleprompterTransferTask { voice.cancelFile(task); teleprompterTransferTask = nil }
            }
            teleprompterStatus = "控制 type\(type) 已提交，等待眼镜回应"
        }
    }
    /// The ASR follower sends progress on the same prepared manuscript; it does
    /// not replace the file or suspend recognition after a glasses gesture.
    @discardableResult
    func teleprompterSeek(pageOffset: Int, highlightOffset: Int) -> Bool {
        do {
            guard let did = teleprompterID, teleprompterDevice == voice.deviceID,
                  teleprompterPrepared, teleprompterStarted,
                  teleprompterBoundaries.contains(pageOffset),
                  teleprompterBoundaries.contains(highlightOffset) else { throw DeviceFeatureError.noSession }
            let message = try TeleprompterJSONCodec().encodeAppRequest(.progress(did: did,
                pageOffset: Int64(pageOffset), highLightOffset: Int64(highlightOffset), autoSync: false))
            guard let body = try JSONSerialization.jsonObject(with: message.payload) as? [String: Any] else {
                throw DeviceFeatureError.invalidPacket
            }
            try send(20, UInt32(message.type), body)
            return true
        } catch {
            teleprompterFailed("提词位置更新失败；已停止自动跟随，保留当前稿件。")
            return false
        }
    }
    private func teleprompterFailed(_ message: String) {
        teleprompterTransfer.cancel(); teleprompterTransferGeneration = UUID()
        if let task = teleprompterTransferTask, teleprompterDevice == voice.deviceID { voice.cancelFile(task) }
        teleprompterTransferTask = nil
        teleprompterPrepared = false
        teleprompterStarted = false
        teleprompterStatus = message
        teleprompterTransferError = message
        error = message
        onTeleprompterFailure?(message)
    }
    private func applyTeleprompterTransfer(_ decision: TeleprompterTransferPolicy.Decision) {
        switch decision {
        case .ready:
            guard !teleprompterPrepared else { return }
            teleprompterPrepared = true; teleprompterTransferProgress = 100
            teleprompterStatus = "文件传输和眼镜收稿均已确认，可以开始提词"
        case .wait:
            guard !teleprompterPrepared, !teleprompterStarted else { return }
            if teleprompterTransfer.fileCompleteBool {
                teleprompterStatus = "文件传输已完成，等待眼镜确认稿件"
            } else if teleprompterTransfer.businessCompleteBool {
                teleprompterStatus = "眼镜已确认稿件，等待文件传输完成回应"
            }
        case .reject: teleprompterFailed("提词稿传输或收稿确认失败，请退出本轮后重试。")
        case .startFile: break
        }
    }
    func teleprompterFileEvent(device: String, task: String, stage: Int, progress: Int?,
                              fileName: String?, failure: String?) {
        guard device == voice.deviceID, device == teleprompterDevice,
              task == teleprompterTransferTask, let did = teleprompterID,
              teleprompterTransfer.fileRequestedBool, !teleprompterTransfer.isTerminal else { return }
        if stage <= 1, teleprompterTransfer.fileCompleteBool { return }
        switch stage {
        case 0: teleprompterStatus = "正在向眼镜传输提词稿"
        case 1:
            if let progress, (0...100).contains(progress) {
                teleprompterTransferProgress = progress
                teleprompterStatus = "提词稿传输 \(progress)% · 等待完整收稿确认"
            }
        case 2:
            guard fileName == did else {
                teleprompterFailed("传输完成的文件名与当前稿件不一致，未开始提词。")
                return
            }
            applyTeleprompterTransfer(teleprompterTransfer.fileCompleted(success: true))
            teleprompterTransferTask = nil
        case 3:
            _ = teleprompterTransfer.fileCompleted(success: false)
            let message: String
            switch failure {
            case "localNetworkUnauthorized": message = "提词稿传输缺少本地网络权限，请在 iPhone 设置中允许 Turbo IO 的本地网络访问。"
            case "bleUnavailable": message = "眼镜蓝牙文件通道不可用，请确认连接后重试。"
            case "apUnavailable": message = "眼镜无线文件通道不可用，请检查眼镜连接后重试。"
            default: message = "提词稿文件传输失败，请退出本轮后重试。"
            }
            teleprompterFailed(message)
        default: break
        }
    }
    /// Removes only this session's generated regular file after transfer has
    /// stopped. Manuscripts are separately stored in the manuscript library.
    private func discardTeleprompterFile() {
        guard let did = teleprompterID, let file = teleprompterFile else { return }
        let directory = inbox.root.deletingLastPathComponent()
            .appendingPathComponent("TeleprompterOutboxV1").standardizedFileURL
        let target = file.standardizedFileURL
        guard target.deletingLastPathComponent().path == directory.path,
              target.lastPathComponent == did,
              let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return }
        try? FileManager.default.removeItem(at: target)
    }
    /// SDK submission is not delivery. A delayed failure from another device or
    /// an older manuscript is ignored; an owned failure freezes voice following.
    func teleprompterTransportFailed(device: String, packet: Data, code: Int) {
        guard device == voice.deviceID, device == teleprompterDevice,
              let did = teleprompterID,
              let wire = try? DeviceBusinessWire(packet),
              [2, 3, 4, 5, 6, 7, 8].contains(wire.type),
              DeviceBusinessWire.identifier(wire.json, "did") == did,
              DeviceBusinessWire.integer(wire.json, "action") == 1 else { return }
        teleprompterFailed("眼镜提词命令发送失败 code=\(code)；已停止自动跟随，请结束本轮后重试。")
    }
    private func teleprompterReceive(_ device: String, _ wire: DeviceBusinessWire) throws {
        guard let did = DeviceBusinessWire.identifier(wire.json,"did"), did == teleprompterID, teleprompterDevice == device else { return }
        let action = DeviceBusinessWire.integer(wire.json,"action"), code = DeviceBusinessWire.integer(wire.json,"code")
        if wire.type == 2, action == 2 {
            guard !teleprompterTransfer.isTerminal else { return }
            let decision = teleprompterTransfer.prepareReply(code: Int(code ?? -1))
            if decision == .startFile {
                guard let file = teleprompterFile, file.lastPathComponent == did else { throw DeviceFeatureError.noSession }
                do {
                    teleprompterTransferTask = try voice.sendFile(file,id:did)
                    teleprompterSentFile = true
                    applyTeleprompterTransfer(teleprompterTransfer.fileSubmissionSucceeded())
                    teleprompterStatus = "文件传输已开始，等待传输完成和眼镜收稿"
                } catch {
                    teleprompterFailed("提词稿文件未能提交到眼镜，请退出本轮后重试。")
                    return
                }
                let transferGeneration = teleprompterTransferGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                    guard let self, self.teleprompterID == did,
                          self.teleprompterTransferGeneration == transferGeneration,
                          !self.teleprompterPrepared else { return }
                    self.teleprompterFailed(self.teleprompterTransfer.fileCompleteBool
                        ? "文件已送达，但眼镜未确认文稿，已保持手机原稿，请退出后重试。"
                        : "两分钟内未完成提词稿传输，请检查连接和本地网络权限。")
                }
            } else { applyTeleprompterTransfer(decision) }
            return
        }
        if wire.type == 3, action == 2 {
            guard code == 1, teleprompterPrepared else {
                teleprompterFailed("开始提词未确认 code=\(code ?? -1)")
                return
            }
            teleprompterStarted = true
            teleprompterStatus = "眼镜已回应开始提词"
            onTeleprompterControl?(3)
            return
        }
        guard let control = TeleprompterControlType(rawValue: UInt16(clamping:wire.type)) else { return }
        let data = try JSONSerialization.data(withJSONObject:wire.json)
        if action == 1 {
            let event = try TeleprompterJSONCodec().decodeGlassesRequest(type:control.rawValue,payload:data)
            let ack = try TeleprompterJSONCodec().encodeAppResponse(type:control,did:did,code:.accepted)
            try voice.sendBusiness(20,payload:DeviceBusinessWire.encode(type:UInt32(ack.type),json:JSONSerialization.jsonObject(with:ack.payload) as! [String:Any]))
            switch event {
            case .progress(let p):
                guard teleprompterStarted else { return }
                guard
                      p.pageOffset >= 0, p.pageOffset <= 48_000,
                      p.highLightOffset >= 0, p.highLightOffset <= 48_000,
                      teleprompterBoundaries.contains(Int(p.pageOffset)),
                      teleprompterBoundaries.contains(Int(p.highLightOffset)) else {
                    // A gesture must never tear down the recognizer. Firmware
                    // layout/normalization can report an unmappable position;
                    // preserve the current anchor instead of guessing a unit.
                    teleprompterStatus = "眼镜滑动位置暂无法对应原稿；语音识别继续，保留当前位置。"
                    onTeleprompterPositionUnavailable?()
                    return
                }
                teleprompterOffset = p.pageOffset
                teleprompterStatus = "眼镜滑动辅助定位：UTF-8 偏移 \(p.pageOffset)"
                onTeleprompterProgress?(p)
            case .pause:
                teleprompterStatus = "眼镜请求暂停"
                onTeleprompterControl?(4)
            case .resume:
                teleprompterStatus = "眼镜请求恢复"
                onTeleprompterControl?(5)
            case .stop:
                teleprompterStatus = "眼镜已请求退出"
                onTeleprompterControl?(6)
            default: return
            }
        } else if action == 2 {
            guard code == 1 else {
                teleprompterFailed("眼镜提词控制未确认 type\(wire.type) code=\(code ?? -1)")
                return
            }
            teleprompterStatus = "眼镜回应 type\(wire.type) code=1"
            if control != .progress { onTeleprompterControl?(wire.type) }
        }
        if control == .stop, action == 1 || code == 1 {
            if let task = teleprompterTransferTask { voice.cancelFile(task); teleprompterTransferTask = nil }
            discardTeleprompterFile()
            teleprompterID = nil; teleprompterPrepared = false; teleprompterStarted = false; teleprompterFile = nil
            teleprompterBoundaries.removeAll()
            teleprompterDocument = nil
            teleprompterTransfer.cancel(); teleprompterTransferGeneration = UUID()
        }
    }
}
