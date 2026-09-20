import SwiftUI
import RayNeoCaptions

struct RealtimeCaptionView: View {
    @EnvironmentObject private var runtime: CaptionRuntime
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CaptionOptions()
    @State private var key = ""
    @State private var confirm = false
    @State private var keyStored = false
    var body: some View {
        NavigationStack {
            Form {
                Section("实时字幕 · V1 实验") {
                    Text(runtime.status).accessibilityIdentifier("realtime-caption-status")
                    if runtime.active { Text("本次 \(runtime.elapsed / 60) 分 \(runtime.elapsed % 60) 秒") }
                    Text("只做语音转文字，不调用 DeepSeek。先开启待命，再主动唤醒眼镜；关闭此页面不会结束字幕，请使用停止按钮。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("锁屏/后台是尽力运行，不保证保活。iOS、蓝牙或眼镜固件可能终止音频；进程被杀后不会自动重新录音。")
                        .font(.caption).foregroundStyle(.orange)
                    if !runtime.supportsDevice { Text("当前是本地预览构建；不连接转写服务，不采音。") }
                }
                Section("转写服务") {
                    Picker("服务", selection: $draft.service) {
                        ForEach(CaptionService.allCases, id: \.self) { service in
                            Text(service.name).tag(service)
                        }
                    }.accessibilityIdentifier("caption-service")
                    LabeledContent("模型", value: draft.service.model)
                    if draft.service == .azure {
                        TextField("Region，例如 eastus", text: $draft.region)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    SecureField("API Key（留空沿用已保存的密钥）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(keyStored ? "当前服务已有本机 Key" : "当前服务尚未保存 Key").font(.caption)
                    Picker("识别语言", selection: $draft.language) {
                        Text("English (UK)").tag("en-GB")
                        Text("English (US)").tag("en-US")
                        Text("普通话").tag("zh-CN")
                    }
                    if draft.service == .elevenLabs {
                        Text("ElevenLabs 将英式/美式选项统一识别为英语。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("保存设置与密钥") { saveSettings() }
                    Button("移除当前服务的本机密钥", role: .destructive) {
                        runtime.forgetKey(options: draft); key = ""; refreshKey()
                    }.disabled(!keyStored)
                    Text("各服务的密钥分别保存在此 iPhone 的钥匙串，Azure 另按 Region 区分。只连接所选服务的官方接口；切换服务不会清除字幕历史。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(runtime.active || !runtime.supportsDevice)
                Section("本次会话") {
                    Picker("无人声多久后退出", selection: $draft.idleSeconds) {
                        ForEach(CaptionOptions.idleChoices, id: \.self) { seconds in
                            Text(seconds == 0 ? "不按静音退出" : "\(seconds / 60) 分钟").tag(seconds)
                        }
                    }
                    Picker("本次最长运行", selection: $draft.maximumSeconds) {
                        ForEach(CaptionOptions.durationChoices, id: \.self) { seconds in
                            Text("\(seconds / 60) 分钟").tag(seconds)
                        }
                    }
                    Toggle("本次额外保存音频", isOn: $draft.recordAudio)
                    Text("默认只存文字。录音为每段最多 60 秒的 WAV，约 115 MB/小时；只保存实际收到的音频，缺口不会补齐。无人声由本地 VAD 判断，嘈杂环境可能误判。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(runtime.active)
                Section {
                    if runtime.active {
                        Button("停止字幕、上传和本地录音", role: .destructive) { runtime.stop() }
                            .disabled(runtime.phase == .stopping)
                    } else {
                        Button("开启字幕待命") { confirm = true }
                            .disabled(!runtime.supportsDevice || !voice.ready)
                    }
                    if let error = runtime.error { Text(error).foregroundStyle(.red).font(.caption) }
                }
                Section("流式字幕") {
                    if !runtime.partial.isEmpty {
                        Text(runtime.partial).foregroundStyle(.secondary).privacySensitive()
                        Text("识别中，文字可能变化").font(.caption)
                    }
                    ForEach(runtime.recent.suffix(8)) { entry in Text(entry.text).privacySensitive() }
                    Text("镜片仅提交最新文字窗口，不是固定行数排版；提交成功不代表镜片已渲染。完整定稿保存在历史。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("字幕历史、导出与录音") { CaptionHistoryView(root: runtime.root) }
                }
            }
            .navigationTitle("实时字幕")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭页面") { dismiss() } } }
            .onAppear {
                voice.prepare(); draft = runtime.options
                if !runtime.active { draft.recordAudio = false }
                keyStored = runtime.hasKey(options: draft)
            }
            .onChange(of: draft.region) { _ in key = ""; refreshKey() }
            .onChange(of: draft.service) { _ in key = ""; runtime.error = nil; refreshKey() }
            .onChange(of: runtime.active) { active in if !active { draft.recordAudio = false } }
            .confirmationDialog("唤醒后将眼镜音频上传到你选择的 \(draft.service.name) 服务，可能计费；本机会保存字幕。请先告知并征得参与者同意。此模式会关闭原有语音助手待命。", isPresented: $confirm, titleVisibility: .visible) {
                Button(draft.recordAudio ? "同意上传并保存字幕及音频" : "同意上传并仅保存字幕") {
                    let session = draft
                    if saveSettings() { runtime.arm(session) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
    private func refreshKey() { keyStored = runtime.hasKey(options: draft) }
    @discardableResult private func saveSettings() -> Bool {
        let saved = runtime.save(draft, newKey: key)
        if saved { key = ""; keyStored = runtime.hasKey(options: draft) }
        return saved
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
