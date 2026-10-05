import SwiftUI
import UIKit
import UniformTypeIdentifiers
import RayNeoCaptions

/// The manuscript library remains available without a device or microphone permission.
struct PrompterWorkspaceView: View {
    @EnvironmentObject private var library: ManuscriptLibrary
    @EnvironmentObject private var runtime: SpeechPrompterRuntime
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var tuning: PrompterSettingsStore
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var editor: ManuscriptEditorRequest?
    @State private var session: PrompterSessionRequest?
    @State private var importing = false
    @State private var deleting: PrompterManuscript?
    @State private var showDelete = false
    @State private var tuningPresented = false
    private var occupied: Bool { runtime.active || features.teleprompterID != nil }
    private var visible: [PrompterManuscript] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.manuscripts.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        Screen(title: "提词器", eyebrow: "以稿为主 · 语音跟随 · 滑动辅助") {
            Button { tuningPresented = true } label: {
                Card { FeatureRow(icon: "slider.horizontal.3", title: "提词设置", subtitle: "提词方式 · 速度 · 旋钮 · 调试", status: "调节") }
            }.buttonStyle(.plain).accessibilityIdentifier("prompter-tuning-entry")
            if let document = library.selected {
                selectedCard(document)
            } else {
                Card {
                    EmptyState(icon: "text.alignleft", title: "准备你的第一份演讲稿", detail: "保存多份稿件，选择一份开始演讲。\n停顿或临场发挥时保持原位，回到稿件后继续跟随。")
                }
            }
            HStack(spacing: 12) {
                Button { editor = ManuscriptEditorRequest() } label: {
                    Label("新建稿件", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityIdentifier("prompter-new")
                Button { importing = true } label: {
                    Label("导入文件", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityIdentifier("prompter-import")
            }.font(.subheadline.weight(.medium)).foregroundStyle(Palette.green)
                .background(.white, in: RoundedRectangle(cornerRadius: 14)).disabled(occupied)
            SectionLabel(title: "我的稿件", trailing: "\(library.manuscripts.count) 份")
            TextField("搜索标题或内容", text: $search).textFieldStyle(.roundedBorder)
                .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                .accessibilityIdentifier("prompter-search")
            if visible.isEmpty && !library.manuscripts.isEmpty {
                Text("没有找到匹配的稿件").font(.subheadline).foregroundStyle(Palette.muted)
            }
            ForEach(visible) { document in manuscriptRow(document) }
            if features.teleprompterID != nil || features.teleprompterTransferError != nil {
                Card {
                    Label("眼镜文稿传输", systemImage: "arrow.up.doc").font(.headline)
                    Text(features.teleprompterStatus).font(.subheadline).foregroundStyle(Palette.muted)
                    if let error = features.teleprompterTransferError {
                        Text(error).font(.subheadline).foregroundStyle(Palette.amber)
                    }
                    if features.teleprompterID != nil, !runtime.active {
                        Button("结束本轮眼镜提词") { features.teleprompterControl(6) }
                            .disabled(!features.voice.ready)
                    }
                }
            }
            if !library.manuscripts.isEmpty {
                Text("点选稿件切换；长按可编辑、复制、导出或删除。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if occupied {
                Text("演讲期间可以滑动辅助定位。切换或编辑稿件，请先结束当前演讲。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            NavigationLink { BookShelfView() } label: {
                Card { FeatureRow(icon: "books.vertical", title: "从书籍准备稿件", subtitle: "TXT / EPUB · 章节阅读 · 创建独立稿件", status: "打开") }
            }.buttonStyle(.plain).disabled(occupied).accessibilityIdentifier("book-shelf")
        }
        .sheet(item: $editor) { ManuscriptEditorView(request: $0) }
        .sheet(isPresented: $tuningPresented) { PrompterSettingsView() }
        .fullScreenCover(item: $session) { PrompterSessionView(document: $0.document, initialMode: $0.mode) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .text]) { result in
            switch result {
            case .success(let url):
                if !occupied { _ = library.importFile(url) }
            case .failure: library.error = "未能打开所选文件，请重试。"
            }
        }
        .alert("删除稿件", isPresented: $showDelete) {
            Button("删除稿件", role: .destructive) {
                if !occupied, let document = deleting { _ = library.delete(document.id) }
                deleting = nil
            }
            Button("保留稿件", role: .cancel) { deleting = nil }
        } message: { Text("删除“\(deleting?.title ?? "")”？删除后无法恢复。") }
        .alert("稿件提示", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("知道了", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
    private func selectedCard(_ document: PrompterManuscript) -> some View {
        Card {
            HStack {
                Badge(text: runtime.active ? "正在演讲" : "当前稿件", active: true)
                Spacer()
                Text("\(document.text.count) 字").font(.caption).foregroundStyle(Palette.muted)
            }
            Text(document.title).font(.title2.bold()).foregroundStyle(Palette.ink)
                .accessibilityIdentifier("prompter-selected-title")
            Text(document.text.isEmpty ? "还没有正文，编辑后即可开始。" : document.text)
                .font(.subheadline).foregroundStyle(Palette.muted).lineLimit(3)
            if document.readingUTF8Offset > 0 {
                Text("已保存阅读位置 · \(Int(Double(document.readingUTF8Offset) / Double(max(1, document.text.utf8.count)) * 100))%")
                    .font(.caption).foregroundStyle(Palette.green)
            }
            PrimaryButton(title: runtime.active ? "返回演讲" : "打开提词", icon: "play.fill", enabled: !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                session = sessionRequest(document, mode: tuning.tuning.preferredMode)
            }.accessibilityIdentifier("prompter-open-session")
            Button {
                session = sessionRequest(document, mode: "uniform")
            } label: {
                Label(features.teleprompterIsUniformSession ? "返回匀速提词" : "打开匀速提词", systemImage: "timer")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }.disabled(runtime.active || document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("prompter-open-uniform")
            if !occupied {
                Button("编辑当前稿件") { editor = ManuscriptEditorRequest(document: document) }
                    .font(.subheadline).accessibilityIdentifier("prompter-edit-current")
            }
        }
    }
    private func sessionRequest(_ document: PrompterManuscript, mode: String) -> PrompterSessionRequest {
        let effective = runtime.active ? "speech" : (features.teleprompterIsUniformSession ? "uniform" : mode)
        return PrompterSessionRequest(document: document, mode: effective)
    }
    private func manuscriptRow(_ document: PrompterManuscript) -> some View {
        Button {
            guard !occupied || document.id == library.selectedID else { return }
            _ = library.select(document.id)
        } label: {
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: library.selectedID == document.id ? "checkmark.circle.fill" : "doc.text")
                        .font(.title3).foregroundStyle(Palette.green)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(document.title).font(.headline).foregroundStyle(Palette.ink)
                        Text("\(document.text.count) 字 · \(document.modifiedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(Palette.muted)
                        Text(document.text.isEmpty ? "空白稿件" : document.text).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(occupied && document.id != library.selectedID)
            .accessibilityIdentifier("prompter-manuscript-\(document.id.uuidString)")
            .accessibilityLabel(document.title).accessibilityValue(library.selectedID == document.id ? "已选择" : "未选择")
            .contextMenu {
                Button("编辑或重命名", systemImage: "pencil") { editor = ManuscriptEditorRequest(document: document) }.disabled(occupied)
                Button("复制稿件", systemImage: "doc.on.doc") { _ = library.duplicate(document.id) }.disabled(occupied)
                ShareLink(item: document.text, subject: Text(document.title)) { Label("导出正文", systemImage: "square.and.arrow.up") }
                Button("删除", systemImage: "trash", role: .destructive) { deleting = document; showDelete = true }.disabled(occupied)
            }
    }
}

private struct PrompterSessionRequest: Identifiable {
    var id: UUID { document.id }
    let document: PrompterManuscript
    let mode: String
}

private struct ManuscriptEditorRequest: Identifiable {
    let id = UUID()
    var document: PrompterManuscript? = nil
}

private struct ManuscriptEditorView: View {
    let request: ManuscriptEditorRequest
    @EnvironmentObject private var library: ManuscriptLibrary
    @EnvironmentObject private var runtime: SpeechPrompterRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var confirmDiscard = false
    init(request: ManuscriptEditorRequest) {
        self.request = request
        _title = State(initialValue: request.document?.title ?? "")
        _text = State(initialValue: request.document?.text ?? "")
    }
    private var changed: Bool { title != (request.document?.title ?? "") || text != (request.document?.text ?? "") }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("稿件标题", text: $title).font(.title3.weight(.semibold)).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("prompter-editor-title")
                HStack {
                    Text("正文").font(.headline)
                    Spacer(); Text("\(text.count) 字").font(.caption).foregroundStyle(Palette.muted)
                }
                TextEditor(text: $text).scrollContentBackground(.hidden).padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("prompter-input")
                if let error = library.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                Text("稿件保存到本机。修改正文后，阅读位置将从开头重新开始。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }.padding(20).background(Palette.background)
                .navigationTitle(request.document == nil ? "新建稿件" : "编辑稿件")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { if changed { confirmDiscard = true } else { dismiss() } }
                            .accessibilityIdentifier("prompter-editor-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runtime.active)
                            .accessibilityIdentifier("prompter-save")
                    }
                }
                .interactiveDismissDisabled(changed)
                .alert("尚有未保存的修改", isPresented: $confirmDiscard) {
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                } message: { Text("继续编辑可以保留当前输入；放弃修改会丢弃尚未保存的内容。") }
        }
    }
    private func save() {
        guard !runtime.active else { return }
        if let document = request.document {
            if library.save(id: document.id, title: title, text: text) { dismiss() }
        } else if library.create(title: title, text: text) != nil { dismiss() }
    }
}

private struct PrompterSessionView: View {
    let document: PrompterManuscript
    @EnvironmentObject private var library: ManuscriptLibrary
    @EnvironmentObject private var runtime: SpeechPrompterRuntime
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var recognitionSettings: SubtitleSettingsStore
    @EnvironmentObject private var tuning: PrompterSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("companion.prompter.output.v1") private var storedOutput = "glasses"
    @AppStorage("companion.prompter.input.v1") private var storedInput = "glasses"
    @AppStorage("companion.prompter.font.v1") private var fontSize = 26.0
    @State private var mode: String
    @State private var offset: Int
    @State private var playing = false
    @State private var uniformProgress: Double
    @State private var jumpProgress: Double
    @State private var jumpID = UUID()
    @State private var settings = false
    @State private var debugExpanded = false
    @State private var lastUniformSaveAt: TimeInterval = -.infinity
    init(document: PrompterManuscript, initialMode: String = "speech") {
        self.document = document
        _mode = State(initialValue: initialMode)
        _offset = State(initialValue: document.readingUTF8Offset)
        let progress = Double(document.readingUTF8Offset) / Double(max(1, document.text.utf8.count))
        _uniformProgress = State(initialValue: progress)
        _jumpProgress = State(initialValue: progress)
    }
    private var output: SpeechPrompterRuntime.Output { SpeechPrompterRuntime.Output(rawValue: storedOutput) ?? .glasses }
    private var input: SpeechPrompterRuntime.Input { SpeechPrompterRuntime.Input(rawValue: storedInput) ?? .glasses }
    private var script: String { runtime.active && runtime.documentID == document.id ? runtime.text : document.text }
    private var followingPaused: Bool { runtime.followState == .paused }
    private var position: Int { runtime.active && runtime.documentID == document.id ? runtime.displayedUTF8Offset : offset }
    private var displayedDiagnostic: SpeechDiagnosticPosition? {
        if runtime.active && runtime.documentID == document.id { return runtime.displayedPosition }
        return SpeechDiagnosticTextMap(text: script).displayedPosition(atUTF8Offset: position)
    }
    private var matchedDiagnostic: SpeechDiagnosticPosition? {
        runtime.active && runtime.documentID == document.id ? runtime.matchedPosition : nil
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("提词方式", selection: $mode) {
                    Text("语音跟随").tag("speech"); Text("匀速滚动").tag("uniform")
                }.pickerStyle(.segmented).disabled(runtime.active || features.teleprompterID != nil)
                    .accessibilityIdentifier("prompter-mode")
                if mode == "speech" {
                    speechHeader
                    if tuning.tuning.debugMode { debugPanel }
                    SpeechPrompterReadingText(text: script, displayedOffset: position, fontSize: fontSize,
                        debugMode: tuning.tuning.debugMode, matchedRange: matchedDiagnostic?.wordRangeUTF8,
                        displayedRange: displayedDiagnostic?.utf8Range, assist: seek)
                        .frame(maxHeight: .infinity).accessibilityIdentifier("prompter-reader")
                } else {
                    uniformReader
                }
            }.padding(.horizontal, 18).padding(.bottom, 8).background(Palette.background)
                .safeAreaInset(edge: .bottom) { sessionFooter }
                .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(runtime.active || features.teleprompterID != nil ? "结束演讲" : "关闭") {
                            runtime.stop(); playing = false; saveUniform()
                            if features.teleprompterID != nil { features.teleprompterControl(6) }
                            dismiss()
                        }.accessibilityIdentifier("prompter-end-session")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(tuning.tuning.debugMode ? "调试开" : "调试") { tuning.update(\.debugMode, !tuning.tuning.debugMode) }
                            .font(.caption.weight(.semibold))
                            .accessibilityLabel(tuning.tuning.debugMode ? "关闭调试" : "打开调试")
                            .accessibilityValue(tuning.tuning.debugMode ? "1" : "0")
                            .accessibilityIdentifier("prompter-debug-toggle")
                        Button { settings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("提词设置").accessibilityIdentifier("prompter-session-settings")
                    }
                }
                .interactiveDismissDisabled(runtime.active || features.teleprompterID != nil)
                .sheet(isPresented: $settings) { PrompterSettingsView() }
                .onAppear {
                    if runtime.active { mode = "speech" }
                    else if features.teleprompterIsUniformSession { mode = "uniform"; storedOutput = "glasses" }
                    tuning.update(\.preferredMode, mode)
                }
                .onChange(of: mode) { _ in playing = false; saveUniform(); tuning.update(\.preferredMode, mode) }
                .onChange(of: playing) { value in if !value { saveUniform() } }
                .onChange(of: features.teleprompterOffset) { _ in
                    let now = ProcessInfo.processInfo.systemUptime
                    if mode == "uniform", output == .glasses,
                       features.teleprompterIsUniformSession, now - lastUniformSaveAt >= 2 {
                        saveUniform(); lastUniformSaveAt = now
                    }
                }
                .onChange(of: scenePhase) { value in if value != .active { playing = false; saveUniform() } }
                .onDisappear { playing = false; saveUniform() }
        }
    }
    private var sessionFooter: some View {
        VStack(spacing: 8) {
            if mode == "speech" { speechControls }
            else if output == .glasses {
                GlassesPrompterControls(text: script, title: document.title, initialOffset: position, compact: true)
            } else {
                PrimaryButton(title: playing ? "暂停匀速滚动" : "开始手机匀速滚动", icon: playing ? "pause.fill" : "play.fill") {
                    if uniformProgress >= 0.999 { uniformProgress = 0; jumpProgress = 0; jumpID = UUID() }
                    playing.toggle()
                }.accessibilityIdentifier("prompter-phone-uniform-start")
            }
            if mode != "uniform" || output == .phone {
                HStack {
                    Text("手机字号").font(.caption)
                    Slider(value: $fontSize, in: 18...38, step: 1)
                    Text("\(Int(fontSize))").font(.caption.monospacedDigit())
                }
            }
            Text(mode == "speech" ? "滑动辅助定位，识别继续运行。" : (output == .glasses ? "眼镜按固定速度滚动，无需语音识别。" : "拖动可暂停；匀速模式无需语音识别。"))
                .font(.caption2).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 18).padding(.vertical, 10).background(Palette.background)
    }
    private var speechHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !runtime.active {
                HStack {
                    Picker("显示", selection: $storedOutput) {
                        ForEach(SpeechPrompterRuntime.Output.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                    }.accessibilityIdentifier("prompter-output")
                    Picker("收音", selection: $storedInput) {
                        ForEach(SpeechPrompterRuntime.Input.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                    }.accessibilityIdentifier("prompter-input-route")
                }.font(.subheadline)
            }
            HStack {
                Label(followLabel, systemImage: runtime.active ? "mic.fill" : "mic.slash")
                    .foregroundStyle(runtime.followState == .uncertain ? Palette.amber : Palette.green)
                Spacer()
                Text(readingProgressLabel)
                    .font(.caption.monospacedDigit())
            }.font(.subheadline.weight(.medium)).accessibilityIdentifier("prompter-follow-state")
            Text(runtime.status).font(.caption).foregroundStyle(Palette.muted)
                .accessibilityIdentifier("prompter-status")
            if !runtime.active && output == .glasses && !voice.ready {
                Text("请先连接眼镜，或选择手机提词并使用 iPhone 麦克风。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if !runtime.active && !recognitionSettings.requirements.isEmpty {
                Button("配置语音识别：\(recognitionSettings.requirements.joined(separator: "、"))") { settings = true }
                    .font(.caption).foregroundStyle(Palette.green)
            }
            if !runtime.active && input == .glasses && output != .glasses {
                Text("使用眼镜麦克风时，请将显示位置选择为眼镜。")
                    .font(.caption).foregroundStyle(Palette.amber)
            }
            if let route = runtime.microphoneRoute, runtime.active {
                Text("正在收音：\(route)").font(.caption2).foregroundStyle(Palette.muted)
            }
            if let error = runtime.error { Text(error).font(.caption).foregroundStyle(Palette.amber).accessibilityIdentifier("prompter-error") }
        }
    }
    private var followLabel: String {
        guard runtime.active else { return "等待跟随" }
        if runtime.phase == .preparing { return "正在准备" }
        switch runtime.followState {
        case .waiting: return "等待跟随"
        case .following: return "跟随中"
        case .uncertain: return "暂时对不上 · 保持原位"
        case .paused: return "暂停跟随 · 仍在监听"
        case .finished: return "已识别到稿件结尾"
        }
    }
    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("跟随调试", systemImage: "waveform.path").font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "RMS %.3f · 匹配 %.2f", runtime.audioRMS, runtime.similarity)).font(.caption2.monospacedDigit())
                    .accessibilityIdentifier("prompter-debug-level")
                Button { debugExpanded.toggle() } label: { Image(systemName: debugExpanded ? "chevron.up" : "chevron.down") }
                    .accessibilityLabel(debugExpanded ? "收起调试信息" : "展开调试信息")
            }
            Text("识别原文\(runtime.lastRecognitionIsFinal ? "（最终）" : "（实时）")：\(recognitionPreview)")
                .font(.caption).lineLimit(debugExpanded ? 5 : 2).truncationMode(.head).accessibilityIdentifier("prompter-debug-recognition")
            HStack(alignment: .top) {
                diagnosticLabel("最近匹配", position: matchedDiagnostic, fallback: "等待匹配")
                    .accessibilityIdentifier("prompter-debug-matched")
                Spacer()
                diagnosticLabel("屏幕位置", position: displayedDiagnostic, fallback: "暂无正文")
                    .accessibilityIdentifier("prompter-debug-displayed")
            }.font(.caption2)
            if let marker = matchedDiagnostic ?? displayedDiagnostic {
                (Text(marker.before).foregroundColor(Palette.muted)
                    + Text(marker.highlight).foregroundColor(Palette.green).bold()
                    + Text(marker.after).foregroundColor(Palette.muted))
                    .font(.caption).lineLimit(2).accessibilityIdentifier("prompter-debug-context")
            }
            if debugExpanded {
                if runtime.followState == .uncertain {
                diagnosticLabel("待确认位置", position: runtime.candidatePosition, fallback: "无候选位置").font(.caption2)
                }
                Text("匹配确认 \(runtime.confirmedUTF8Offset) 字节 · 显示 \(position) 字节")
                    .font(.caption2.monospacedDigit())
                Text("黄色为最近匹配词，橙色为屏幕阅读位置；识别匹配表示内容的大致末尾。")
                    .font(.caption2).foregroundStyle(Palette.muted)
                if output == .glasses { rotaryDebugDetails }
            }
        }.padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("prompter-debug-panel")
    }
    private func diagnosticLabel(_ title: String, position: SpeechDiagnosticPosition?, fallback: String) -> Text {
        guard let position else { return Text("\(title)：\(fallback)") }
        return Text("\(title)：第 \(position.characterIndex + 1) 字 · \(position.word)")
    }
    private var recognitionPreview: String {
        guard !runtime.recognitionText.isEmpty else { return "等待语音识别" }
        let limit = debugExpanded ? 400 : 120
        return runtime.recognitionText.count > limit ? "…" + String(runtime.recognitionText.suffix(limit)) : runtime.recognitionText
    }
    private var rotaryDebugDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("旋钮原始 \(features.teleprompterRotaryRawOffset.map(String.init) ?? "—") → 应用 \(features.teleprompterRotaryAppliedOffset.map(String.init) ?? "—") 字节")
                .font(.caption2.monospacedDigit())
            Text(features.teleprompterLastPositionKind).font(.caption2).foregroundStyle(Palette.muted)
        }.accessibilityIdentifier("prompter-debug-rotary")
    }
    private var readingProgressLabel: String {
        let total = Double(max(1, script.utf8.count))
        let percent = Int(Double(position) * 100 / total)
        return "\(percent)%"
    }
    private var speechControls: some View {
        HStack(spacing: 12) {
            Button { moveRow(-1) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }
                .accessibilityLabel("辅助向前")
            if runtime.active {
                PrimaryButton(title: followingPaused ? "继续跟随" : "暂停跟随", icon: followingPaused ? "play.fill" : "pause.fill", enabled: runtime.phase == .listening) {
                    if followingPaused { runtime.resumeFollowing() } else { runtime.pauseFollowing() }
                }.accessibilityIdentifier("prompter-pause-follow")
            } else {
                PrimaryButton(title: "开始语音跟随", icon: "mic.fill", enabled: runtime.canStart(output: output, input: input)) {
                    guard let current = library.manuscripts.first(where: { $0.id == document.id }) else { return }
                    _ = runtime.start(document: current, output: output, input: input)
                }.accessibilityIdentifier("prompter-start-follow")
            }
            Button { moveRow(1) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                .accessibilityLabel("辅助向后")
        }.foregroundStyle(Palette.green)
    }
    private var uniformReader: some View {
        VStack(spacing: 12) {
            Picker("匀速显示", selection: $storedOutput) {
                ForEach(SpeechPrompterRuntime.Output.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
            }.pickerStyle(.segmented).disabled(features.teleprompterID != nil)
                .accessibilityIdentifier("prompter-uniform-output")
            HStack {
                Text(output == .glasses ? "眼镜匀速速度" : "手机匀速速度")
                Slider(value: Binding(get: { output == .glasses ? Double(tuning.tuning.fixedSpeed) : tuning.tuning.phoneSpeed }, set: {
                    if output == .glasses { tuning.update(\.fixedSpeed, Int($0)) }
                    else { tuning.update(\.phoneSpeed, $0) }
                }), in: output == .glasses ? 60...240 : 8...80, step: output == .glasses ? 10 : 2)
                Text(output == .glasses ? "\(tuning.tuning.fixedSpeed)" : "\(Int(tuning.tuning.phoneSpeed)) 点/秒").monospacedDigit()
            }.font(.caption)
            HStack {
                Text(output == .glasses ? "眼镜匀速提词" : (playing ? "正在匀速滚动" : "等待开始"))
                Spacer()
                Text(output == .glasses ? "\(Int(Double(features.teleprompterOffset) / Double(max(1, script.utf8.count)) * 100))%" : "\(Int(uniformProgress * 100))%")
                    .monospacedDigit().accessibilityIdentifier("prompter-uniform-progress")
            }.font(.subheadline).foregroundStyle(Palette.green)
            if tuning.tuning.debugMode && output == .glasses { rotaryDebugDetails }
            UniformReadingText(text: script, fontSize: fontSize, speed: tuning.tuning.phoneSpeed, playing: $playing,
                progress: $uniformProgress, jumpID: jumpID, jumpProgress: jumpProgress, allowsTrailingScroll: true)
                .clipShape(RoundedRectangle(cornerRadius: 18)).frame(maxHeight: .infinity)
        }
        .onChange(of: storedOutput) { _ in playing = false }
    }
    private func seek(_ target: Int) {
        offset = validOffset(target, in: script)
        if runtime.active { runtime.assist(toUTF8Offset: offset) }
        else { _ = library.savePosition(id: document.id, utf8Offset: offset) }
    }
    private func moveRow(_ delta: Int) {
        let rows = PrompterReadingRow.rows(script)
        guard !rows.isEmpty else { return }
        let index = rows.lastIndex(where: { $0.start <= position }) ?? 0
        seek(rows[min(rows.count - 1, max(0, index + delta))].start)
    }
    private func saveUniform() {
        guard mode == "uniform", !runtime.active else { return }
        let target: Int
        if output == .glasses {
            guard features.teleprompterIsUniformSession else { return }
            target = validOffset(Int(features.teleprompterOffset), in: script)
        } else {
            target = validOffset(Int(uniformProgress * Double(document.text.utf8.count)), in: document.text)
        }
        _ = library.savePosition(id: document.id, utf8Offset: target)
    }
    private func validOffset(_ target: Int, in text: String) -> Int {
        let limit = min(text.utf8.count, max(0, target))
        var boundary = 0
        for character in text {
            let next = boundary + String(character).utf8.count
            if next > limit { break }
            boundary = next
        }
        return boundary
    }
}

private struct PrompterReadingRow: Identifiable {
    var id: Int { start }
    let start: Int, end: Int, text: String
    /// Chunks preserve exact source byte offsets, including whitespace and line breaks.
    static func rows(_ text: String) -> [Self] {
        var rows: [Self] = [], current = "", width = 0, start = 0, offset = 0
        for character in text {
            current.append(character)
            offset += String(character).utf8.count
            width += character.unicodeScalars.contains(where: { $0.value > 0x2E7F }) ? 2 : 1
            if character == "\n" || (width >= 48 && character.isWhitespace) || width >= 68 {
                rows.append(Self(start: start, end: offset, text: current))
                current = ""; width = 0; start = offset
            }
        }
        if !current.isEmpty { rows.append(Self(start: start, end: offset, text: current)) }
        return rows
    }
}

/// TextKit supplies real wrapped-line geometry. The display follows a bounded
/// reading cursor with pixel interpolation instead of replacing whole chunks.
private struct SpeechPrompterReadingText: UIViewRepresentable {
    let text: String, displayedOffset: Int, fontSize: Double
    let debugMode: Bool
    let matchedRange: Range<Int>?, displayedRange: Range<Int>?
    let assist: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false; view.isSelectable = false
        view.backgroundColor = UIColor(Palette.ink)
        view.textContainerInset = UIEdgeInsets(top: 35, left: 16, bottom: 220, right: 16)
        view.layer.cornerRadius = 18
        view.delegate = context.coordinator; context.coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let c = context.coordinator; c.owner = self
        let changed = view.text != text || c.fontSize != fontSize
        if changed {
            c.fontSize = fontSize; c.rebuildIndex()
            let style = NSMutableParagraphStyle(); style.lineSpacing = 10
            view.attributedText = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: UIColor(Palette.mint), .paragraphStyle: style])
        }
        c.applyHighlights(force: changed)
        guard !view.isDragging && !view.isDecelerating else { return }
        DispatchQueue.main.async { [weak c, weak view] in
            guard let c, let view, !view.isDragging, !view.isDecelerating else { return }
            view.layoutIfNeeded(); c.updateTarget(immediate: changed || !c.initialized)
        }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.stopAnimation(); view.delegate = nil
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var owner: SpeechPrompterReadingText
        weak var view: UITextView?
        var fontSize: Double?
        var boundaries: [(byte: Int, utf16: Int)] = []
        var targetY: CGFloat = 0
        var initialized = false
        var link: CADisplayLink?
        var last: CFTimeInterval?
        var highlightedMatchedRange: Range<Int>?, highlightedDisplayedRange: Range<Int>?
        var highlightedDebugMode = false
        init(_ owner: SpeechPrompterReadingText) { self.owner = owner }
        func rebuildIndex() {
            var byte = 0, utf16 = 0; boundaries = [(0, 0)]
            for character in owner.text {
                let fragment = String(character)
                byte += fragment.utf8.count; utf16 += fragment.utf16.count
                boundaries.append((byte, utf16))
            }
        }
        func utf16(forByte byte: Int) -> Int { boundaries.last(where: { $0.byte <= byte })?.utf16 ?? 0 }
        func byte(forUTF16 utf16: Int) -> Int { boundaries.last(where: { $0.utf16 <= utf16 })?.byte ?? 0 }
        func applyHighlights(force: Bool) {
            let matched = owner.debugMode ? owner.matchedRange : nil
            let displayed = owner.debugMode ? owner.displayedRange : nil
            guard let view, force || highlightedDebugMode != owner.debugMode || highlightedMatchedRange != matched || highlightedDisplayedRange != displayed else { return }
            highlightedDebugMode = owner.debugMode
            highlightedMatchedRange = matched; highlightedDisplayedRange = displayed
            let all = NSRange(location: 0, length: view.textStorage.length)
            view.textStorage.beginEditing()
            view.textStorage.removeAttribute(.backgroundColor, range: all)
            view.textStorage.addAttribute(.foregroundColor, value: UIColor(Palette.mint), range: all)
            if owner.debugMode {
                highlight(owner.matchedRange, color: UIColor.systemYellow.withAlphaComponent(0.40), in: view)
                highlight(owner.displayedRange, color: UIColor.systemOrange.withAlphaComponent(0.75), in: view)
                let displayText: String
                if let displayed, displayed.lowerBound >= 0, displayed.upperBound <= owner.text.utf8.count {
                    displayText = String(decoding: Array(owner.text.utf8)[displayed], as: UTF8.self)
                } else { displayText = "无" }
                view.accessibilityValue = "调试高亮：屏幕位置 \(displayText)"
            } else { view.accessibilityValue = nil }
            view.textStorage.endEditing()
        }
        private func highlight(_ bytes: Range<Int>?, color: UIColor, in view: UITextView) {
            guard let bytes, bytes.lowerBound >= 0, bytes.upperBound <= owner.text.utf8.count else { return }
            let start = utf16(forByte: bytes.lowerBound), end = utf16(forByte: bytes.upperBound)
            guard end > start, end <= view.textStorage.length else { return }
            let range = NSRange(location: start, length: end - start)
            view.textStorage.addAttributes([.backgroundColor: color, .foregroundColor: UIColor(Palette.ink)], range: range)
        }
        func updateTarget(immediate: Bool) {
            guard let view, !owner.text.isEmpty, view.layoutManager.numberOfGlyphs > 0 else { return }
            let index = min(max(0, utf16(forByte: owner.displayedOffset)), view.textStorage.length - 1)
            let manager = view.layoutManager
            manager.ensureLayout(for: view.textContainer)
            let glyph = manager.glyphIndexForCharacter(at: index)
            var glyphs = NSRange()
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let fraction = min(1, max(0, Double(index - characters.location) / Double(max(1, characters.length))))
            let y = line.minY + CGFloat(fraction) * line.height + view.textContainerInset.top - view.bounds.height * 0.16
            targetY = min(max(0, view.contentSize.height - view.bounds.height), max(0, y))
            initialized = true
            if immediate { stopAnimation(); view.setContentOffset(CGPoint(x: 0, y: targetY), animated: false) }
            else if abs(view.contentOffset.y - targetY) > 0.1, link == nil {
                last = nil
                let link = CADisplayLink(target: self, selector: #selector(tick(_:))); link.preferredFramesPerSecond = 30
                self.link = link; link.add(to: .main, forMode: .common)
            }
        }
        @objc func tick(_ link: CADisplayLink) {
            guard let view, !view.isDragging, !view.isDecelerating else { stopAnimation(); return }
            let elapsed = min(0.1, last.map { link.timestamp - $0 } ?? 1.0 / 30); last = link.timestamp
            let difference = targetY - view.contentOffset.y
            let y = view.contentOffset.y + difference * CGFloat(1 - exp(-elapsed * 10))
            view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            if abs(difference) < 0.1 { stopAnimation() }
        }
        func stopAnimation() { link?.invalidate(); link = nil; last = nil }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { stopAnimation() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { assistVisiblePosition() }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { assistVisiblePosition() }
        private func assistVisiblePosition() {
            guard let view else { return }
            assist(at: CGPoint(x: 0, y: view.contentOffset.y + view.bounds.height * 0.16 - view.textContainerInset.top))
        }
        private func assist(at point: CGPoint) {
            guard let view, view.layoutManager.numberOfGlyphs > 0 else { return }
            let glyph = view.layoutManager.glyphIndex(for: point, in: view.textContainer)
            let utf16 = view.layoutManager.characterIndexForGlyph(at: glyph)
            owner.assist(byte(forUTF16: utf16))
        }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view, recognizer.state == .ended else { return }
            let location = recognizer.location(in: view)
            assist(at: CGPoint(x: location.x - view.textContainerInset.left,
                               y: location.y - view.textContainerInset.top))
        }
    }
}
