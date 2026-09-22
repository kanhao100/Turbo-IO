import SwiftUI
import RayNeoCaptions

struct AlwaysOnView: View {
    @EnvironmentObject private var runtime: AlwaysOnRuntime
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var showSettings = false
    @State private var selectedLanguage = "auto"
    @State private var pendingLanguage: RecognitionLanguageMode?
    @State private var confirmLanguage = false
    @State private var confirmLegacyDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                HStack {
                    Label("全天智记", systemImage: "waveform.and.mic")
                        .font(.headline)
                    Spacer()
                    Badge(text: runtime.enabled ? phaseName : "已关闭", active: runtime.enabled && runtime.phase != .error)
                }
                Text("开启一次后永久记住。同一副眼镜重连或 App 正常重启后自动恢复；只保存文字，不保存任何音频或原始包。")
                    .font(.caption).foregroundStyle(Palette.muted).lineSpacing(4)
                Toggle("永久启用全天智记", isOn: Binding(
                    get: { runtime.enabled }, set: { runtime.setEnabled($0) }
                )).disabled(!runtime.enabled && !runtime.canEnable)
                    .accessibilityIdentifier("always-on-enabled")
                Toggle("自动在眼镜显示字幕", isOn: Binding(
                    get: { runtime.showOnGlasses }, set: { runtime.setShowOnGlasses($0) }
                )).disabled(!runtime.enabled)
                    .accessibilityIdentifier("always-on-lens")
            }

            Card {
                HStack { Text("状态").font(.headline); Spacer(); Text(voice.ready ? "眼镜已连接" : "等待连接").font(.caption).foregroundStyle(Palette.muted) }
                Text(runtime.status).font(.title3.weight(.semibold))
                    .accessibilityIdentifier("always-on-status")
                HStack(spacing: 24) {
                    metric("\(runtime.todaySentences)", "今日定稿")
                    metric("\(runtime.gaps)", "缺口")
                    metric("\(runtime.packets)", "实时包")
                }
                LabeledContent("眼镜协议", value: "LifeLog A1–A8 · Opus 16 kHz")
                    .font(.caption).foregroundStyle(Palette.muted)
                if !runtime.partial.isEmpty {
                    Divider()
                    Text(runtime.partial).font(.title3).foregroundStyle(Palette.green).privacySensitive()
                    Text("识别中 · 仅在内存和镜片显示，定稿后才保存").font(.caption).foregroundStyle(Palette.muted)
                } else if let last = runtime.recent.last {
                    Divider(); Text(last.text).font(.title3).privacySensitive()
                }
                if runtime.cachedPackets > 0 {
                    Label("收到 \(runtime.cachedPackets) 个缓存包；为避免重复或乱序，本版未转写，已记录 gap。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Palette.amber)
                }
            }

            Card {
                Text("识别设置").font(.headline)
                Picker("语言", selection: $selectedLanguage) {
                    Text("自动检测").tag("auto")
                    Text("中文").tag("zh-CN")
                    Text("English · US").tag("en-US")
                    Text("English · UK").tag("en-GB")
                }
                LabeledContent("当前服务", value: runtime.serviceSummary)
                    .font(.subheadline)
                Button("服务、模型与 API Key") { showSettings = true }
                Text("运行中修改时可立即重连 ASR，或留到下一次 A1 任务生效。立即应用不会重启眼镜采音，但可能产生短暂缺口。")
                    .font(.caption).foregroundStyle(Palette.muted)
                if runtime.settings.options.service == .deepgram && selectedLanguage == "auto" {
                    Text("Deepgram Nova-3 当前需要固定语言；不会自动回退到其他服务。")
                        .font(.caption).foregroundStyle(Palette.amber)
                }
            }

            if let error = runtime.error {
                Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Palette.amber)
            }
            NavigationLink { AlwaysOnHistoryView() } label: {
                Card { FeatureRow(icon: "calendar", title: "全天智记历史", subtitle: "按自然日查看、搜索、导出或删除", status: "仅文字", active: true) }
            }.buttonStyle(.plain)
            if runtime.legacyDiagnosticsAvailable || runtime.legacyDeletionStatus != nil {
                Card {
                    Text("旧诊断数据").font(.headline)
                    Text("旧版 30 秒探针可能留下 .rnp 原始包。新版不会继续生成，也不会自动删除。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    if runtime.legacyDiagnosticsAvailable {
                        Button("删除旧诊断数据", role: .destructive) { confirmLegacyDelete = true }
                    }
                    if let status = runtime.legacyDeletionStatus {
                        Text(status).font(.caption).foregroundStyle(Palette.amber)
                    }
                }
            }
            ShareLink("分享脱敏诊断", item: runtime.diagnosticText).font(.subheadline)
            Text("正常锁屏或切到后台时依靠眼镜外设连接继续运行。若从多任务界面强制结束 App，iOS 不会让 App 继续接收眼镜音频。")
                .font(.caption).foregroundStyle(Palette.muted)
        }
        .sheet(isPresented: $showSettings) { SubtitleSettingsView() }
        .confirmationDialog("何时应用新的识别语言？", isPresented: $confirmLanguage) {
            Button("立即应用并重连 ASR") { applyPending(.immediately) }
            Button("下一次眼镜语音任务生效") { applyPending(.nextTask) }
            Button("取消", role: .cancel) { pendingLanguage = nil; syncLanguage() }
        } message: { Text("立即应用只重连云端 ASR；眼镜采音不会重新启动。") }
        .confirmationDialog("永久删除旧版全天智记探针数据？", isPresented: $confirmLegacyDelete) {
            Button("永久删除", role: .destructive) { runtime.deleteLegacyDiagnostics() }
            Button("取消", role: .cancel) {}
        } message: { Text("只删除旧 AlwaysOnLocalProbeV1 目录；不会删除新版文字历史。此操作无法恢复。") }
        .onAppear { syncLanguage() }
        .onChange(of: selectedLanguage) { value in
            let mode: RecognitionLanguageMode = value == "auto" ? .automatic : .fixed(localeIdentifier: value)
            guard mode != runtime.languageMode else { return }
            pendingLanguage = mode
            if runtime.activeTask { confirmLanguage = true } else { applyPending(.nextTask) }
        }
    }

    private var phaseName: String {
        switch runtime.phase {
        case .transcribing: return "转写中"
        case .reconnectingASR: return "ASR 重连"
        case .waitingForA1: return "等待声音"
        case .waitingForDevice: return "等待眼镜"
        case .error: return "需要处理"
        default: return "已开启"
        }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title2.monospacedDigit()); Text(label).font(.caption).foregroundStyle(Palette.muted) }
    }
    private func applyPending(_ policy: AlwaysOnApplyPolicy) {
        guard let mode = pendingLanguage else { return }
        if !runtime.setLanguage(mode, policy: policy) { syncLanguage() }
        pendingLanguage = nil
    }
    private func syncLanguage() {
        switch runtime.languageMode {
        case .automatic: selectedLanguage = "auto"
        case .fixed(let locale): selectedLanguage = locale
        }
    }
}

struct AlwaysOnHistoryView: View {
    @EnvironmentObject private var archive: AlwaysOnTranscriptArchive
    var body: some View {
        List {
            if archive.days.isEmpty && !archive.loading {
                Text("还没有全天智记文字。定稿内容会按本地自然日出现在这里。")
                    .foregroundStyle(Palette.muted)
            }
            ForEach(archive.days) { day in
                NavigationLink { AlwaysOnDayView(day: day.day) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(day.day).font(.headline)
                        Text("\(day.finalCount) 句 · \(day.gapCount) 个缺口 · \(day.entryCount) 条事件")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
            if let error = archive.error { Text(error).foregroundStyle(Palette.amber) }
        }
        .overlay { if archive.loading { ProgressView("读取文字历史…") } }
        .navigationTitle("全天智记历史")
        .toolbar(.visible, for: .navigationBar)
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
        .task { await archive.load() }
        .refreshable { await archive.load() }
    }
}

struct AlwaysOnDayView: View {
    let day: String
    @EnvironmentObject private var archive: AlwaysOnTranscriptArchive
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AlwaysOnTranscriptEntry] = []
    @State private var search = ""
    @State private var exportURL: URL?
    @State private var confirmDelete = false
    @State private var loading = true
    @State private var error: String?

    private var visible: [AlwaysOnTranscriptEntry] {
        entries.filter { [.final, .unfinished, .gap, .system].contains($0.kind) &&
            (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        List {
            TextField("搜索当天文字", text: $search)
            ForEach(visible) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit())
                        Spacer(); Text(label(entry.kind)).font(.caption2).foregroundStyle(entry.kind == .gap ? Palette.amber : Palette.green)
                    }
                    Text(entry.text).textSelection(.enabled).privacySensitive()
                }.padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(Palette.amber) }
            Section("导出与管理") {
                Button("生成 TXT") { export(false) }
                Button("生成结构化 ZIP") { export(true) }
                if let exportURL { ShareLink("分享 \(exportURL.pathExtension.uppercased())", item: exportURL) }
                Button("永久删除这一天", role: .destructive) { confirmDelete = true }
            }
        }
        .overlay { if loading { ProgressView("读取中…") } }
        .navigationTitle(day).toolbar(.visible, for: .navigationBar)
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
        .task { await load() }
        .confirmationDialog("永久删除 \(day) 的全部文字？", isPresented: $confirmDelete) {
            Button("永久删除", role: .destructive) { Task { await archive.delete(day: day); dismiss() } }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作不可撤销，不会影响其他日期。") }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { entries = try await archive.entries(for: day); error = nil }
        catch { self.error = "无法读取这一天的文字；原文件未修改。" }
    }
    private func export(_ zip: Bool) {
        Task {
            do {
                if zip { exportURL = try await archive.exportZIP(day: day) }
                else { exportURL = try await archive.exportText(day: day) }
                error = nil
            }
            catch { self.error = "导出失败；历史原文未修改。" }
        }
    }
    private func label(_ kind: AlwaysOnTranscriptKind) -> String {
        switch kind { case .final: return "定稿"; case .unfinished: return "未定稿"; case .gap: return "缺口"; case .system: return "系统"; case .started: return "开始"; case .stopped: return "停止" }
    }
}
