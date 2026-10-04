import SwiftUI
import RayNeoCaptions
import RayNeoProtocol

struct RealtimeSubtitlesView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var runtime: SubtitleRealtimeRuntime
    @EnvironmentObject private var latency: SubtitleLatencyDiagnostics
    @EnvironmentObject private var settings: SubtitleSettingsStore
    @EnvironmentObject private var archive: SubtitleArchiveStore
    @EnvironmentObject private var alwaysOn: AlwaysOnRuntime
    @State private var page = 0
    @State private var showSettings = false
    @State private var showDisplayTest = false
    @State private var search = ""
    @State private var selectedHistoryDate: Date?
    @State private var calendarDate = Date()
    @State private var showHistoryCalendar = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("字幕").font(.largeTitle.bold()).foregroundStyle(Palette.ink)
                            Text("实时查看，也可以全天只记文字").font(.subheadline).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.title2).padding(12).background(.white, in: Circle()) }
                            .accessibilityLabel("字幕设置").accessibilityIdentifier("realtime-settings")
                    }
                    Picker("字幕页面", selection: $page) {
                        Text("实时字幕").tag(0); Text("全天智记").tag(1); Text("历史记录").tag(2)
                    }.pickerStyle(.segmented).accessibilityIdentifier("realtime-pages")
                    if page == 0 { liveContent }
                    else if page == 1 { AlwaysOnView() }
                    else { historyContent }
                }.padding(20).padding(.bottom, 85)
            }.background(Palette.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showSettings) { SubtitleSettingsView() }
                .sheet(isPresented: $showDisplayTest) { SubtitleDisplayTestView() }
                .task { store.features.prepare(); runtime.prepare(); await archive.load() }
        }
    }
    private var liveContent: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(runtime.canStop ? "实时会话" : "实时字幕", systemImage: runtime.canStop ? "waveform" : "captions.bubble")
                    Spacer()
                    Text(connectionStatus).font(.caption).padding(7).background(.white.opacity(0.12), in: Capsule())
                }.font(.subheadline.weight(.medium))
                Text(runtime.status).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("realtime-status")
                Label(settings.inputSource.name, systemImage: settings.inputSource == .glasses ? "eyeglasses" : "mic.fill")
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("realtime-input-source")
                if let route = runtime.microphoneRoute {
                    Label("实际输入：\(route)", systemImage: "waveform")
                        .font(.caption)
                        .accessibilityIdentifier("realtime-microphone-route")
                }
                if runtime.active && settings.inputSource != .glasses && settings.showOnGlasses {
                    Label(runtime.glassesOutputReady ? "手机和眼镜显示" : "仅手机显示",
                          systemImage: runtime.glassesOutputReady ? "eyeglasses" : "iphone")
                        .font(.caption)
                        .accessibilityIdentifier("realtime-output-route")
                }
                HStack(spacing: 22) {
                    metric(SubtitleTime.string(Double(runtime.elapsed)), label: "会话时长")
                    metric(SubtitleTime.string(runtime.audioSeconds), label: "已收音频")
                    metric("\(runtime.recent.count)", label: "最近定稿")
                }
                ProgressView(value: runtime.audioLevel).tint(Palette.mint).accessibilityLabel("实际收到的音频电平")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.options.service.name)
                        Text(settings.options.selectedModel).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer()
                    Label(settings.options.recordAudio ? "文本 + 音频" : "仅文本", systemImage: settings.options.recordAudio ? "waveform" : "doc.text")
                }.font(.caption).foregroundStyle(.white.opacity(0.75))
            }.padding(22).foregroundStyle(.white)
                .background(LinearGradient(colors: [Palette.ink, Palette.green], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
            Card {
                HStack { Label("此刻的字幕", systemImage: "text.bubble"); Spacer(); Badge(text: runtime.cloudReady ? "识别已就绪" : (runtime.active ? "准备中" : "待开始"), active: runtime.cloudReady) }
                    .font(.subheadline.weight(.semibold))
                Text(effectiveDisplayModeName)
                    .font(.caption).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("realtime-display-mode")
                if runtime.displayText.isEmpty {
                    Text(runtime.active
                         ? "正在聆听，下一句字幕生成后会显示在这里。"
                         : "开始后，所选麦克风收到的声音会逐句出现。\n无需向 AI 提问，也不会生成回答。")
                        .font(.title3).foregroundStyle(Palette.muted).lineSpacing(7)
                        .frame(maxWidth: .infinity, minHeight: 95, alignment: .leading)
                } else {
                    if settings.displayLayout == .rolling {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(runtime.displaySourceLines.indices, id: \.self) { index in
                                Text(runtime.displaySourceLines[index])
                                    .foregroundStyle(runtime.displayIsPartial ? Palette.green : Palette.ink)
                            }
                            if !runtime.displaySourceLines.isEmpty && !runtime.displayTranslationLines.isEmpty {
                                Divider()
                            }
                            ForEach(runtime.displayTranslationLines.indices, id: \.self) { index in
                                Text(runtime.displayTranslationLines[index]).foregroundStyle(Palette.ink)
                            }
                        }
                        .font(.system(.title3, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.5)
                        .textSelection(.enabled).privacySensitive()
                        .accessibilityIdentifier("realtime-display-text")
                    } else {
                    Text(runtime.displayText).font(.title3).lineSpacing(6)
                        .foregroundStyle(runtime.displayIsPartial ? Palette.green : Palette.ink)
                        .textSelection(.enabled).privacySensitive()
                        .accessibilityIdentifier("realtime-display-text")
                    }
                    if runtime.displayIsPartial {
                        Text("识别中 · 内容可能修订").font(.caption).foregroundStyle(Palette.muted)
                    } else if runtime.displayIsAwaitingTranslation {
                        Text("原文已识别 · 正在翻译").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if runtime.gaps > 0 { Label("检测到 \(runtime.gaps) 处音频缺口，已记录到历史", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber) }
            }
            if settings.inputSource == .glasses {
                Card {
                    Label("眼镜收音方向", systemImage: "mic.circle").font(.subheadline.weight(.semibold))
                    Picker("收音范围", selection: Binding(
                        get: { settings.pickupDirection },
                        set: { runtime.setPickupDirection($0) }
                    )) {
                        Text("四周").tag(SubtitleTranslateWire.PickupDirection.around)
                        Text("前方").tag(SubtitleTranslateWire.PickupDirection.ahead)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!runtime.canChangePickupDirection)
                    .accessibilityIdentifier("realtime-pickup-direction")
                    if let message = runtime.pickupDirectionMessage {
                        Text(message).font(.caption).foregroundStyle(Palette.amber)
                    } else if runtime.active {
                        Text(runtime.canChangePickupDirection ? "切换会沿当前字幕会话发送指令。" : "字幕启动完成后可切换。")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                    if runtime.pickupDirectionNeedsRetry {
                        Button("重试收音切换") { runtime.retryPickupDirection() }
                            .accessibilityIdentifier("realtime-pickup-direction-retry")
                    }
                }
            }
            if runtime.canStop {
                PrimaryButton(title: "停止并保存", icon: "stop.fill") { runtime.stop() }.accessibilityIdentifier("realtime-stop")
            } else if alwaysOn.enabled {
                PrimaryButton(title: "前往关闭全天智记", icon: "arrow.right.circle") { page = 1 }
                    .accessibilityIdentifier("realtime-close-always-on")
                Text("全天智记正在使用语音识别。关闭后再启动普通实时字幕；这里不会暗中抢占或改动永久设置。")
                    .font(.caption).foregroundStyle(Palette.amber)
            } else if voice.enabled {
                PrimaryButton(title: "先关闭语音待命", icon: "stop.circle") { voice.stop() }
                Text("语音待命运行时，请先关闭再使用手机或系统麦克风收音。")
                    .font(.caption).foregroundStyle(Palette.amber)
            } else if !settings.requirements.isEmpty {
                PrimaryButton(title: "配置转写服务", icon: "key") { showSettings = true }.accessibilityIdentifier("realtime-configure")
            } else {
                PrimaryButton(title: "开始实时字幕", icon: "mic.fill", enabled: runtime.canStart) {
                    store.subtitlePlayback.stop(); _ = runtime.start()
                }
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
                Label(shortcutHint, systemImage: "hand.tap")
                Spacer(); Button("设置") { showSettings = true }
            }.font(.caption).foregroundStyle(Palette.muted)
            Text(sessionHint)
                .font(.caption).foregroundStyle(Palette.muted)
            if latency.enabled { latencyCard }
            DisclosureGroup("显示测试与诊断") {
                Button("打开已验证的上屏测试") { showDisplayTest = true }.disabled(runtime.active || runtime.saving)
                NavigationLink {
                    LocalAudioTranscriptionExperimentView()
                } label: {
                    Label("导入录音测试 Apple 本机识别", systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(runtime.active || runtime.saving)
                .accessibilityIdentifier("subtitle-imported-audio-experiment")
                ShareLink("分享脱敏诊断", item: runtime.diagnosticText)
                ShareLink("分享延迟实验报告", item: latency.report)
            }.font(.subheadline)
        }
    }
    private var connectionStatus: String {
        if settings.inputSource == .glasses { return voice.ready ? "眼镜已连接" : "等待眼镜" }
        if settings.showOnGlasses && voice.ready { return "眼镜已连接" }
        return "无需眼镜"
    }
    private var effectiveDisplayModeName: String {
        if settings.translationEnabled { return settings.displayMode.name }
        return settings.options.language.hasPrefix("zh") ? "只看中文" : "只看英文"
    }
    private var shortcutHint: String {
        if settings.inputSource == .glasses {
            return runtime.shortcutEnabled ? "双击：开始 / 停止并保存（永久）" : "双击字幕可在设置中启用"
        }
        return "使用所选录音输入收音"
    }
    private var sessionHint: String {
        if settings.inputSource == .glasses {
            return "运行时无需打开手机：再次双击眼镜即可停止并保存。锁屏与正常后台会继续使用外设连接；强制结束 App 或断连会结束当前会话。"
        }
        return settings.showOnGlasses
            ? "音频来自所选录音输入。眼镜连接且空闲时可同步显示字幕；眼镜不会被要求启动收音。"
            : "音频来自所选录音输入，字幕在手机上显示。"
    }
    private var latencyCard: some View {
        Card {
            HStack {
                Label("延迟实验", systemImage: "stopwatch")
                Spacer(); Badge(text: runtime.active ? "\(latency.serviceName) · 记录中" : latency.serviceName, active: runtime.active)
            }.font(.subheadline.weight(.semibold))
            ForEach(SubtitleLatencyDiagnostics.Metric.allCases, id: \.rawValue) { metric in
                let value = latency.snapshot(metric)
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.rawValue).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(value.count == 0 ? "—" : "\(value.last) ms · 均 \(value.average) ms")
                        .monospacedDigit().foregroundStyle(Palette.ink)
                }.font(.caption)
            }
            Text("只记时间元数据。眼镜端无同钟采集时间戳，“启动确认 → 首包”用于发现链路等待，不代表绝对单向延迟。")
                .font(.caption2).foregroundStyle(Palette.muted)
            Text(latency.assessment).font(.caption).foregroundStyle(Palette.green)
        }
    }
    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.title2.monospacedDigit().weight(.medium)); Text(label).font(.caption).foregroundStyle(.white.opacity(0.65)) }
    }
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("搜索会话名称或最近字幕", text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("subtitle-history-search")
            HStack(spacing: 12) {
                Button {
                    showHistoryCalendar.toggle()
                } label: {
                    Label(selectedHistoryDate.map { "日期：\($0.formatted(date: .abbreviated, time: .omitted))" } ?? "按日期筛选", systemImage: "calendar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("subtitle-history-calendar-toggle")
                if selectedHistoryDate != nil {
                    Button("清除日期") { selectedHistoryDate = nil; showHistoryCalendar = false }
                        .accessibilityIdentifier("subtitle-history-clear-date")
                }
            }
            if showHistoryCalendar {
                Card {
                    DatePicker("选择会话日期", selection: $calendarDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .onChange(of: calendarDate) { _, date in
                            selectedHistoryDate = date
                            showHistoryCalendar = false
                        }
                        .accessibilityIdentifier("subtitle-history-calendar")
                    Button("筛选所选日期") {
                        selectedHistoryDate = calendarDate
                        showHistoryCalendar = false
                    }
                    .accessibilityIdentifier("subtitle-history-apply-date")
                    Button("筛选今天") {
                        let today = Date()
                        calendarDate = today
                        selectedHistoryDate = today
                        showHistoryCalendar = false
                    }
                    .accessibilityIdentifier("subtitle-history-today")
                }
            }
            if archive.loading { ProgressView("正在读取会话…") }
            if archive.sessions.isEmpty {
                Card { EmptyState(icon: "text.book.closed", title: "每次对话，都有迹可循", detail: "结束字幕后，文本与音频会保存在同一会话中。可回听、改名、导出或删除。") }
            } else if filteredHistorySessions.isEmpty && !archive.loading {
                Card { EmptyState(icon: "calendar.badge.exclamationmark", title: "没有找到会话", detail: "试试其他日期或搜索词，也可以清除日期筛选。") }
            }
            ForEach(filteredHistorySessions) { record in
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
    private var filteredHistorySessions: [SubtitleSessionRecord] {
        archive.sessions.filter { record in
            let matchesSearch = search.isEmpty || record.title.localizedCaseInsensitiveContains(search)
                || (record.preview ?? "").localizedCaseInsensitiveContains(search)
            let matchesDate = selectedHistoryDate.map { Calendar.current.isDate(record.createdAt, inSameDayAs: $0) } ?? true
            return matchesSearch && matchesDate
        }
    }
}

enum SubtitleTime {
    static func string(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
