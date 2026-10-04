import SwiftUI
import UniformTypeIdentifiers
import RayNeoCaptions

/// The manuscript library remains available without a device or microphone permission.
struct PrompterWorkspaceView: View {
    @EnvironmentObject private var library: ManuscriptLibrary
    @EnvironmentObject private var runtime: SpeechPrompterRuntime
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @State private var search = ""
    @State private var editor: ManuscriptEditorRequest?
    @State private var session: PrompterManuscript?
    @State private var importing = false
    @State private var deleting: PrompterManuscript?
    @State private var showDelete = false
    private var occupied: Bool { runtime.active || features.teleprompterID != nil }
    private var visible: [PrompterManuscript] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.manuscripts.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        Screen(title: "提词器", eyebrow: "以稿为主 · 语音跟随 · 滑动辅助") {
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
                .accessibilityIdentifier("prompter-search")
            if visible.isEmpty && !library.manuscripts.isEmpty {
                Text("没有找到匹配的稿件").font(.subheadline).foregroundStyle(Palette.muted)
            }
            ForEach(visible) { document in manuscriptRow(document) }
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
        .fullScreenCover(item: $session) { PrompterSessionView(document: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .text]) { result in
            switch result {
            case .success(let url):
                if !occupied { _ = library.importFile(url) }
            case .failure: library.error = "未能打开所选文件，请重试。"
            }
        }
        .confirmationDialog("删除“\(deleting?.title ?? "")”？删除后无法恢复。", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除稿件", role: .destructive) {
                if !occupied, let document = deleting { _ = library.delete(document.id) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
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
                session = document
            }.accessibilityIdentifier("prompter-open-session")
            if !occupied {
                Button("编辑当前稿件") { editor = ManuscriptEditorRequest(document: document) }
                    .font(.subheadline).accessibilityIdentifier("prompter-edit-current")
            }
        }
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
            }
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
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runtime.active)
                            .accessibilityIdentifier("prompter-save")
                    }
                }
                .interactiveDismissDisabled(changed)
                .confirmationDialog("尚有未保存的修改", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("companion.prompter.output.v1") private var storedOutput = "glasses"
    @AppStorage("companion.prompter.input.v1") private var storedInput = "glasses"
    @AppStorage("companion.prompter.font.v1") private var fontSize = 26.0
    @State private var mode = "speech"
    @State private var offset: Int
    @State private var playing = false
    @State private var uniformProgress: Double
    @State private var jumpProgress: Double
    @State private var jumpID = UUID()
    @State private var speed = 24.0
    @State private var settings = false
    init(document: PrompterManuscript) {
        self.document = document
        _offset = State(initialValue: document.readingUTF8Offset)
        let progress = Double(document.readingUTF8Offset) / Double(max(1, document.text.utf8.count))
        _uniformProgress = State(initialValue: progress)
        _jumpProgress = State(initialValue: progress)
    }
    private var output: SpeechPrompterRuntime.Output { SpeechPrompterRuntime.Output(rawValue: storedOutput) ?? .glasses }
    private var input: SpeechPrompterRuntime.Input { SpeechPrompterRuntime.Input(rawValue: storedInput) ?? .glasses }
    private var script: String { runtime.active && runtime.documentID == document.id ? runtime.text : document.text }
    private var followingPaused: Bool { runtime.followState == .paused }
    private var position: Int { runtime.active && runtime.documentID == document.id ? runtime.confirmedUTF8Offset : offset }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("提词方式", selection: $mode) {
                    Text("语音跟随").tag("speech"); Text("匀速阅读").tag("uniform")
                }.pickerStyle(.segmented).disabled(runtime.active || features.teleprompterID != nil)
                    .accessibilityIdentifier("prompter-mode")
                if mode == "speech" {
                    speechHeader
                    SpeechPrompterReadingText(text: script, confirmedOffset: position, fontSize: fontSize, assist: seek)
                        .frame(maxHeight: .infinity).accessibilityIdentifier("prompter-reader")
                    speechControls
                } else {
                    uniformReader
                }
                HStack {
                    Text("字号").font(.caption)
                    Slider(value: $fontSize, in: 18...38, step: 1)
                    Text("\(Int(fontSize))").font(.caption.monospacedDigit())
                }
                Text(mode == "speech" ? "滑动或点选稿件只辅助定位，识别继续运行；只有“暂停跟随”会锁住自动推进。" : "拖动暂停匀速滚动；此模式不会开启语音识别。")
                    .font(.caption2).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 18).padding(.bottom, 16).background(Palette.background)
                .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(runtime.active || features.teleprompterID != nil ? "结束演讲" : "关闭") {
                            runtime.stop(); playing = false; saveUniform()
                            if features.teleprompterID != nil { features.teleprompterControl(6) }
                            dismiss()
                        }.accessibilityIdentifier("prompter-end-session")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { settings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("语音识别设置").disabled(runtime.active)
                    }
                }
                .interactiveDismissDisabled(runtime.active || features.teleprompterID != nil)
                .sheet(isPresented: $settings) { SubtitleSettingsView() }
                .onChange(of: mode) { _ in playing = false; saveUniform() }
                .onChange(of: playing) { value in if !value { saveUniform() } }
                .onChange(of: scenePhase) { value in if value != .active { playing = false; saveUniform() } }
                .onDisappear { playing = false; saveUniform() }
        }
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
        case .finished: return "稿件已读完"
        }
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
            UniformReadingText(text: script, fontSize: fontSize, speed: speed, playing: $playing,
                progress: $uniformProgress, jumpID: jumpID, jumpProgress: jumpProgress)
                .clipShape(RoundedRectangle(cornerRadius: 18)).frame(maxHeight: .infinity)
            PrimaryButton(title: playing ? "暂停滚动" : "手机匀速滚动", icon: playing ? "pause.fill" : "play.fill") {
                if uniformProgress >= 0.999 { uniformProgress = 0; jumpProgress = 0; jumpID = UUID() }
                playing.toggle()
            }
            HStack { Text("慢"); Slider(value: $speed, in: 8...80, step: 2); Text("快") }.font(.caption)
            DisclosureGroup("眼镜匀速提词") { GlassesPrompterControls(text: script) }.font(.subheadline)
        }
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
        let target = validOffset(Int(uniformProgress * Double(document.text.utf8.count)), in: document.text)
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

private struct PrompterRowFrames: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SpeechPrompterReadingText: View {
    let text: String
    let confirmedOffset: Int
    let fontSize: Double
    let assist: (Int) -> Void
    @State private var frames: [Int: CGFloat] = [:]
    @State private var dragging = false
    @State private var gestureEnded = false
    @State private var pendingAssist: Task<Void, Never>?
    private var rows: [PrompterReadingRow] { PrompterReadingRow.rows(text) }
    private var currentID: Int { rows.last(where: { $0.start <= confirmedOffset })?.id ?? 0 }
    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            highlighted(row).font(.system(size: fontSize, weight: .medium)).lineSpacing(10)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 9)
                                .background(row.id == currentID ? Palette.mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                .id(row.id).contentShape(Rectangle()).onTapGesture { assist(row.start) }
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: PrompterRowFrames.self, value: [row.id: geometry.frame(in: .named("prompter-reader-scroll")).minY])
                                })
                        }
                        Color.clear.frame(height: viewport.size.height * 0.6)
                    }.padding(.vertical, 24)
                }.coordinateSpace(name: "prompter-reader-scroll")
                    .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 18))
                    .onPreferenceChange(PrompterRowFrames.self) {
                        frames = $0
                        // Inertial scrolling can continue after the finger lifts.
                        // Settle on the final viewport, not a position mid-swipe.
                        if dragging && gestureEnded { scheduleAssistance(height: viewport.size.height) }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
                        pendingAssist?.cancel(); dragging = true; gestureEnded = false
                    }.onEnded { _ in
                        // Only a physical gesture reanchors. Programmatic scrolls never
                        // enter this path, and audio recognition is left running.
                        gestureEnded = true
                        scheduleAssistance(height: viewport.size.height)
                    })
                    .onChange(of: currentID) { id in
                        guard !dragging else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onAppear { proxy.scrollTo(currentID, anchor: .top) }
                    .onDisappear { pendingAssist?.cancel() }
            }
        }
    }
    private func scheduleAssistance(height: CGFloat) {
        pendingAssist?.cancel()
        pendingAssist = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let readingY = height * 0.16
            let visible = frames.filter { $0.value > -100 && $0.value < height }
            let nearest = visible.min { abs($0.value - readingY) < abs($1.value - readingY) }
            if let nearest { assist(nearest.key) }
            dragging = false; gestureEnded = false
        }
    }
    private func highlighted(_ row: PrompterReadingRow) -> Text {
        var consumed = "", upcoming = "", byte = row.start
        for character in row.text {
            if byte < confirmedOffset { consumed.append(character) } else { upcoming.append(character) }
            byte += String(character).utf8.count
        }
        return Text(consumed).foregroundColor(Palette.mint.opacity(0.45)) + Text(upcoming).foregroundColor(Palette.mint)
    }
}
