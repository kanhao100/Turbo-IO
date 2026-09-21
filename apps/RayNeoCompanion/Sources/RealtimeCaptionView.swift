import SwiftUI
import RayNeoCaptions

struct RealtimeCaptionView: View {
    var embedded = false
    @EnvironmentObject private var runtime: CaptionRuntime
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var speech: SpeechSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CaptionOptions()
    @State private var confirm = false
    @State private var showServices = false
    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
    }
    private var content: some View {
        Form {
            Section("实时字幕") {
                Text(runtime.status).accessibilityIdentifier("realtime-caption-status")
                if runtime.active { Text("本次 \(runtime.elapsed / 60) 分 \(runtime.elapsed % 60) 秒") }
                Text("只将语音转为字幕，不需要 DeepSeek。开启待命后主动唤醒眼镜；离开页面不会停止，请使用停止按钮。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("共用转写服务") {
                LabeledContent("服务", value: speech.configuration.service.name)
                LabeledContent("语言", value: speech.configuration.language)
                Button("语音服务设置") { showServices = true }.accessibilityIdentifier("caption-open-services")
                ForEach(speech.captionRequirements, id: \.self) { Text("待配置：" + $0).foregroundStyle(.orange) }
                if voice.enabled { Text("AI 对话正在待命，请先关闭后切换模式。").foregroundStyle(.orange) }
            }
            Section("本次会话") {
                Picker("无人声多久后退出", selection: $draft.idleSeconds) {
                    ForEach(CaptionOptions.idleChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "不按静音退出" : "\(seconds / 60) 分钟").tag(seconds)
                    }
                }
                Picker("本次最长运行", selection: $draft.maximumSeconds) {
                    ForEach(CaptionOptions.durationChoices, id: \.self) { Text("\($0 / 60) 分钟").tag($0) }
                }
                Toggle("本次额外保存音频", isOn: $draft.recordAudio)
                Text("默认只存文字。录音按最多 60 秒分段保存为 WAV，约 115 MB/小时；缺口不会补齐。无人声由本地 VAD 判断，噪声可能影响判断。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(runtime.active)
            Section {
                if runtime.active {
                    Button("停止字幕、上传和本地录音", role: .destructive) { runtime.stop() }
                        .disabled(runtime.phase == .stopping).accessibilityIdentifier("caption-stop")
                } else if !speech.captionRequirements.isEmpty {
                    Button("配置转写服务") { showServices = true }
                } else {
                    Button("开启字幕待命") { confirm = true }
                        .disabled(!runtime.supportsDevice || !voice.ready || voice.enabled)
                        .accessibilityIdentifier("caption-start")
                }
                if !voice.ready { Text(runtime.supportsDevice ? "请先连接并认证眼镜。" : "本地预览不采音、不上传。").font(.caption) }
                if let error = runtime.error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            Section("流式字幕") {
                if !runtime.partial.isEmpty {
                    Text(runtime.partial).foregroundStyle(.secondary).privacySensitive()
                    Text("识别中，文字可能变化").font(.caption)
                }
                ForEach(runtime.recent.suffix(8)) { Text($0.text).privacySensitive() }
                Text("镜片显示最新文字窗口，完整定稿保存在历史。文字提交成功不等于镜片渲染确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("字幕历史、导出与录音") { CaptionHistoryView(root: runtime.root) }
                Text("锁屏和后台运行取决于 iOS、蓝牙和眼镜固件；进程结束后不会自动重新录音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(embedded ? "语音" : "实时字幕")
        .toolbar {
            if !embedded { ToolbarItem(placement: .confirmationAction) { Button("关闭页面") { dismiss() } } }
        }
        .onAppear {
            voice.prepare(); speech.refresh(); draft = runtime.options
            if !runtime.active { draft.recordAudio = false }
        }
        .onChange(of: runtime.active) { if !$0 { draft.recordAudio = false } }
        .sheet(isPresented: $showServices) { VoiceServicesView() }
        .confirmationDialog("唤醒后将眼镜音频上传到 \(speech.configuration.service.name)，可能计费；本机保存字幕。请取得参与者同意。", isPresented: $confirm, titleVisibility: .visible) {
            Button(draft.recordAudio ? "同意上传并保存字幕及音频" : "同意上传并仅保存字幕") {
                let session = draft
                if runtime.save(session) { runtime.arm(session) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct CaptionHistoryItem: Identifiable {
    let id: String
    let directory: URL
    let date: Date
}

private struct CaptionHistoryView: View {
    @EnvironmentObject private var runtime: CaptionRuntime
    let root: URL
    @State private var items: [CaptionHistoryItem] = []
    @State private var message: String?
    @State private var deletion: CaptionHistoryItem?
    var body: some View {
        List {
            if let message { Text(message).foregroundStyle(.orange) }
            if items.isEmpty { Text("还没有字幕历史") }
            ForEach(items) { item in
                NavigationLink {
                    CaptionHistoryDetail(directory: item.directory)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.date, style: .date); Text(item.date, style: .time)
                        Text(item.id.prefix(8)).font(.caption).foregroundStyle(.secondary)
                    }
                }.swipeActions {
                    if !runtime.active { Button("删除", role: .destructive) { deletion = item } }
                }
            }
            Text("字幕和音频仅在此设备保存，不进入 iCloud 备份。删除前可先导出；卸载 App 也会删除。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("字幕历史")
        .task { await reload() }
        .refreshable { await reload() }
        .alert("永久删除这次字幕及音频？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("删除", role: .destructive) {
                guard let item = deletion, !runtime.active else { return }; deletion = nil
                Task {
                    do {
                        try await Task.detached(priority: .utility) {
                            try FileManager.default.removeItem(at: item.directory)
                        }.value
                        await reload()
                    } catch { message = "删除失败" }
                }
            }
            Button("取消", role: .cancel) { deletion = nil }
        } message: { Text("无法恢复。正在运行字幕时不允许删除。") }
    }
    private func reload() async {
        let root = root
        do {
            items = try await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: root.path) else { return [CaptionHistoryItem]() }
                return try FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
                    .compactMap { url -> CaptionHistoryItem? in
                        guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
                        let info = try url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
                        guard info.isDirectory == true, info.isSymbolicLink != true else { return nil }
                        return CaptionHistoryItem(id: url.lastPathComponent, directory: url, date: info.creationDate ?? .distantPast)
                    }.sorted { $0.date > $1.date }
            }.value
        } catch { message = "历史读取失败" }
    }
}

private struct CaptionHistoryDetail: View {
    let directory: URL
    @State private var entries: [CaptionEntry] = []
    @State private var audio: [URL] = []
    @State private var exported: URL?
    @State private var message: String?
    var body: some View {
        List {
            if let message { Text(message).foregroundStyle(.orange) }
            if entries.last?.kind != .stopped {
                Text("会话仍在运行或曾被中断；没有正常结束记录。末尾字幕/录音可能缺失。")
            }
            Section("导出") {
                Button("生成完整文字导出") {
                    let directory = directory
                    Task {
                        do {
                            exported = try await Task.detached(priority: .utility) {
                                let all = try CaptionJournal.load(directory)
                                let url = directory.appendingPathComponent("captions-export.txt")
                                try Data(CaptionJournal.exportText(all).utf8).write(to: url,
                                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                                return url
                            }.value
                        } catch { message = "文字导出失败" }
                    }
                }
                if let exported { ShareLink("分享完整文字", item: exported) }
                Text("时间是手机收到事件的时间；不是音频对齐 SRT。页面只预览最近 200 条，导出包含全部记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("字幕与中断记录") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading) {
                        Text("\(entry.kind.rawValue) · \(entry.date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        Text(entry.text).privacySensitive()
                    }
                }
            }
            Section("实际收到的音频片段") {
                ForEach(audio, id: \.self) { url in ShareLink(url.lastPathComponent, item: url) }
                if audio.isEmpty { Text("本次没有保存音频") }
                Text("按顺序导出 WAV；有缺口时另起一段。进程被杀可能使最后一段的尾部不完整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("字幕记录")
        .task {
            let directory = directory
            do {
                let result = try await Task.detached(priority: .utility) {
                    let entries = try CaptionJournal.load(directory)
                    let audio = try FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { url in
                            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            return url.pathExtension == "wav" && info.isRegularFile == true && info.isSymbolicLink != true
                        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    return (Array(entries.suffix(200)), audio)
                }.value
                entries = result.0; audio = result.1
            } catch { message = "无法读取记录；文件可能损坏。" }
        }
    }
}
