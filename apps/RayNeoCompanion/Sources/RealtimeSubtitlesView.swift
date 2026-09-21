import SwiftUI
import RayNeoCaptions

struct RealtimeSubtitlesView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var runtime: SubtitleRealtimeRuntime
    @EnvironmentObject private var settings: SubtitleSettingsStore
    @EnvironmentObject private var archive: SubtitleArchiveStore
    @State private var page = 0
    @State private var showSettings = false, showDisplayTest = false, confirmStart = false
    @State private var search = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("实时字幕").font(.largeTitle.bold()).foregroundStyle(Palette.ink)
                            Text("听见当下，留住每一句").font(.subheadline).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.title2).padding(12).background(.white, in: Circle()) }
                            .accessibilityLabel("字幕设置").accessibilityIdentifier("realtime-settings")
                    }
                    Picker("字幕页面", selection: $page) {
                        Text("正在转写").tag(0); Text("会话历史").tag(1)
                    }.pickerStyle(.segmented).accessibilityIdentifier("realtime-pages")
                    if page == 0 { liveContent } else { historyContent }
                }.padding(20).padding(.bottom, 85)
            }.background(Palette.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showSettings) { SubtitleSettingsView() }
                .sheet(isPresented: $showDisplayTest) { SubtitleDisplayTestView() }
                .confirmationDialog("开始实时字幕？", isPresented: $confirmStart, titleVisibility: .visible) {
                    Button(settings.options.recordAudio ? "同意上传，并保存文本和音频" : "同意上传，并仅保存文本") {
                        store.subtitlePlayback.stop(); _ = runtime.start(consented: true)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("眼镜音频将发送给 \(settings.options.service.name)，可能计费。\(settings.options.recordAudio ? "本 App 同时保存文本与处理后的 WAV 音频。" : "本 App 只保存文本。")请取得在场人员同意，先结束眼镜上的其他任务。")
                }
                .task { store.features.prepare(); runtime.prepare(); await archive.load() }
        }
    }
    private var liveContent: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(runtime.canStop ? "实时会话" : "眼镜字幕", systemImage: runtime.canStop ? "waveform" : "captions.bubble")
                    Spacer()
                    Text(voice.ready ? "眼镜已连接" : "等待连接").font(.caption).padding(7).background(.white.opacity(0.12), in: Capsule())
                }.font(.subheadline.weight(.medium))
                Text(runtime.status).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("realtime-status")
                HStack(spacing: 22) {
                    metric(SubtitleTime.string(Double(runtime.elapsed)), label: "会话时长")
                    metric(SubtitleTime.string(runtime.audioSeconds), label: "已收音频")
                    metric("\(runtime.recent.count)", label: "最近定稿")
                }
                ProgressView(value: runtime.audioLevel).tint(Palette.mint).accessibilityLabel("实际收到的音频电平")
                HStack {
                    Text(settings.options.service.name)
                    Spacer()
                    Label(settings.options.recordAudio ? "文本 + 音频" : "仅文本", systemImage: settings.options.recordAudio ? "waveform" : "doc.text")
                }.font(.caption).foregroundStyle(.white.opacity(0.75))
            }.padding(22).foregroundStyle(.white)
                .background(LinearGradient(colors: [Palette.ink, Palette.green], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
            Card {
                HStack { Label("此刻的字幕", systemImage: "text.bubble"); Spacer(); Badge(text: runtime.cloudReady ? "转写已连接" : "等待音频", active: runtime.cloudReady) }
                    .font(.subheadline.weight(.semibold))
                if runtime.partial.isEmpty && runtime.recent.isEmpty {
                    Text("开始后，周围的声音会逐句出现。\n无需向 AI 提问，也不会生成回答。")
                        .font(.title3).foregroundStyle(Palette.muted).lineSpacing(7).frame(maxWidth: .infinity, minHeight: 95, alignment: .leading)
                } else {
                    ForEach(runtime.recent.suffix(3)) { entry in Text(entry.text).font(.title3).lineSpacing(6).textSelection(.enabled).privacySensitive() }
                    if !runtime.partial.isEmpty {
                        Text(runtime.partial).font(.title3).lineSpacing(6).foregroundStyle(Palette.green).privacySensitive()
                        Text("识别中 · 内容可能修订").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if runtime.gaps > 0 { Label("检测到 \(runtime.gaps) 处音频缺口，已记录到历史", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber) }
            }
            if runtime.canStop {
                PrimaryButton(title: "停止并保存", icon: "stop.fill") { runtime.stop() }.accessibilityIdentifier("realtime-stop")
            } else if runtime.active {
                Card {
                    Label("本机已停止，确认眼镜退出", systemImage: "checkmark.shield").font(.headline)
                    Text("若镜片仍在字幕页，请先在眼镜退出。已收到的音频与文本保留，退出未确认前不能开启另一会话。")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                    if runtime.canRetryExit { Button("重试退出命令") { runtime.retryExit() } }
                    Button("我确认眼镜已退出") { runtime.confirmExited() }.accessibilityIdentifier("realtime-confirm-exit")
                }
            } else if !settings.requirements.isEmpty {
                PrimaryButton(title: "配置转写服务", icon: "key") { showSettings = true }.accessibilityIdentifier("realtime-configure")
            } else {
                PrimaryButton(title: "开始实时字幕", icon: "mic.fill", enabled: runtime.canStart) { confirmStart = true }
                    .accessibilityIdentifier("realtime-start")
            }
            if runtime.saving { ProgressView("正在完成音频与文本保存…") }
            if let error = runtime.error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Palette.amber) }
            if let saved = runtime.lastSavedID, !runtime.saving {
                NavigationLink { SubtitleSessionDetailView(id: saved) } label: {
                    FeatureRow(icon: "checkmark.circle", title: "查看本次会话", subtitle: "回听音频 · 阅读字幕 · 导出分享", status: "已保存", active: true)
                }.buttonStyle(.plain)
            }
            HStack {
                Label(runtime.shortcutEnabled ? "眼镜发起字幕：已允许" : "双击字幕可在设置中启用", systemImage: "hand.tap")
                Spacer(); Button("设置") { showSettings = true }
            }.font(.caption).foregroundStyle(Palette.muted)
            Text("离开此页面不会停止字幕。锁屏与后台受 iOS 和配件连接限制；断连后不自动恢复录音。")
                .font(.caption).foregroundStyle(Palette.muted)
            DisclosureGroup("显示测试与诊断") {
                Button("打开已验证的上屏测试") { showDisplayTest = true }.disabled(runtime.active || runtime.saving)
                ShareLink("分享脱敏诊断", item: runtime.diagnosticText)
            }.font(.subheadline)
        }
    }
    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.title2.monospacedDigit().weight(.medium)); Text(label).font(.caption).foregroundStyle(.white.opacity(0.65)) }
    }
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("搜索会话名称或最近字幕", text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("subtitle-history-search")
            if archive.loading { ProgressView("正在读取会话…") }
            if archive.sessions.isEmpty {
                Card { EmptyState(icon: "text.book.closed", title: "每次对话，都有迹可循", detail: "结束字幕后，文本与音频会保存在同一会话中。可回听、改名、导出或删除。") }
            }
            ForEach(archive.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.preview ?? "").localizedCaseInsensitiveContains(search) }) { record in
                NavigationLink { SubtitleSessionDetailView(id: record.id) } label: {
                    Card {
                        HStack(alignment: .top) {
                            Image(systemName: record.savesAudio ? "waveform" : "doc.text").font(.title2).foregroundStyle(Palette.green)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(record.title).font(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Palette.muted)
                            }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
                        }
                        if let text = record.preview { Text(text).lineLimit(2).font(.subheadline).foregroundStyle(Palette.muted).privacySensitive() }
                        HStack { Text(SubtitleTime.string(record.audioSeconds)); Text("\(record.finalSentences) 句"); Spacer(); Badge(text: record.state == .completed ? record.service.name : "中断 / 未正常结束", active: record.state == .completed) }.font(.caption).foregroundStyle(Palette.muted)
                    }
                }.buttonStyle(.plain)
            }
            if let error = archive.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
            Button("刷新会话") { Task { await archive.load() } }
        }.task { await archive.load() }
    }
}

enum SubtitleTime {
    static func string(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
