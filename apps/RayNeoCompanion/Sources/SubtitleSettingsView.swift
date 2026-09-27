import SwiftUI
import RayNeoCaptions
import RayNeoProtocol
import Translation

struct SubtitleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var settings: SubtitleSettingsStore
    @EnvironmentObject private var runtime: SubtitleRealtimeRuntime
    @EnvironmentObject private var latency: SubtitleLatencyDiagnostics
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var alwaysOn: AlwaysOnRuntime
    @State private var draft = CaptionOptions()
    @State private var key = ""
    @State private var saved = false
    @State private var confirmApply = false
    @State private var draftInputSource: SubtitleInputSource = .glasses
    @State private var draftInputUID = ""
    @State private var draftTranslationEnabled = false
    @State private var draftShowOnGlasses = true
    @State private var inputPorts: [SubtitleMicrophoneInput.Port] = []
    @State private var inputStatus = ""
    @State private var localModelStatus = ""
    @State private var translationStatus = ""
    @State private var translationConfiguration: TranslationSession.Configuration?
    private var busy: Bool {
        runtime.active || runtime.saving || voice.enabled || (voice.subtitleOwnsDisplay && !alwaysOn.activeTask)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("字幕只需要转写服务", systemImage: "captions.bubble").font(.headline)
                    Text("选用 Apple 本机识别或一家云服务。Apple 模式在设备上转写，不需要 API Key；云服务的 Key 留在本机钥匙串。音频只送往当前所选识别引擎。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("音频来源") {
                    Picker("收音设备", selection: $draftInputSource) {
                        Label("眼镜音频流", systemImage: "eyeglasses").tag(SubtitleInputSource.glasses)
                        Label("iPhone 内置麦克风", systemImage: "iphone").tag(SubtitleInputSource.iPhoneMicrophone)
                        Label("系统麦克风", systemImage: "mic").tag(SubtitleInputSource.systemMicrophone)
                    }
                    .accessibilityIdentifier("subtitle-input-source")
                    Text(inputDescription).font(.caption).foregroundStyle(.secondary)
                    if draftInputSource == .systemMicrophone {
                        Picker("使用的麦克风", selection: $draftInputUID) {
                            Text("跟随系统当前输入").tag("")
                            ForEach(inputPorts, id: \.uid) { port in
                                Text(port.name).tag(port.uid)
                            }
                        }.accessibilityIdentifier("subtitle-system-input")
                        Button("查看可用麦克风") { refreshInputPorts() }
                        if !inputStatus.isEmpty { Text(inputStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                    if draftInputSource != .glasses {
                        Toggle("同时显示在眼镜", isOn: $draftShowOnGlasses)
                        Text("选择眼镜显示时，需要已连接且空闲的眼镜；手机麦克风不会启动眼镜收音。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(busy)
                Section("转写服务") {
                    Picker("服务", selection: $draft.service) { ForEach(CaptionService.allCases, id: \.self) { Text($0.name).tag($0) } }
                        .accessibilityIdentifier("subtitle-provider")
                    if draft.service != .aliyun { LabeledContent("模型", value: draft.service.model) }
                    if draft.service == .appleLocal {
                        Text("iOS 26 本机识别。首次使用需准备所选语言模型；运行时不上传音频。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("准备本机识别模型") { prepareLocalModel() }
                            .accessibilityIdentifier("subtitle-prepare-local-model")
                        if !localModelStatus.isEmpty { Text(localModelStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                    if draft.service == .azure { TextField("Azure Region，例如 eastus", text: $draft.region).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    if draft.service == .aliyun {
                        Picker("阿里云模型", selection: $draft.aliyunModel) {
                            ForEach(AliyunCaptionModel.allCases, id: \.self) { Text($0.name).tag($0) }
                        }.accessibilityIdentifier("subtitle-aliyun-model")
                        Text(draft.aliyunModel.detail).font(.caption).foregroundStyle(.secondary)
                        TextField("阿里云 Workspace Host", text: $draft.aliyunHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let region = AliyunRealtimeRegion.region(for: draft.aliyunHost) {
                            LabeledContent("已识别地域", value: region.name)
                                .foregroundStyle(Palette.green)
                        } else if !draft.aliyunHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("只接受中国北京或新加坡的 Workspace 专属 Host；不接受 URL、DashScope 公共域名或 trial 试用域名。")
                                .font(.caption).foregroundStyle(Palette.amber)
                        }
                        Text("北京与新加坡的 Workspace、API Key 和模型权限彼此隔离。请粘贴控制台显示的完整 Host，并使用同一地域创建的 Key。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.service == .selfHostedQwen {
                        TextField("wss://example.com/compat/openai/v1/realtime", text: $draft.selfHostedEndpoint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()

                        Text("填写完整 WSS Realtime 地址。Key 只发送到这个地址，重定向会被拒绝；该可选端点仅在你主动选中时使用。当前按 1 秒 PCM 窗口提交，不保存音频。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("识别语言", selection: $draft.language) {
                        Text("中文").tag("zh-CN"); Text("English · UK").tag("en-GB"); Text("English · US").tag("en-US")
                    }
                    if draft.service != .appleLocal {
                        SecureField(settings.hasKey(for: draft) ? "已保存密钥，留空保留" : "填写自己的 API Key", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("subtitle-api-key")
                    }
                }.disabled(busy)
                Section("本地翻译") {
                    Toggle("翻译最终字幕", isOn: $draftTranslationEnabled)
                        .accessibilityIdentifier("subtitle-local-translation")
                    Text(translationPairDescription).font(.caption).foregroundStyle(.secondary)
                    if draftTranslationEnabled {
                        Button("准备翻译语言包") { prepareTranslationLanguages() }
                            .accessibilityIdentifier("subtitle-prepare-translation")
                        if !translationStatus.isEmpty { Text(translationStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(busy)
                if draftInputSource == .glasses { Section("实时字幕收音方向") {
                    Picker("收音范围", selection: Binding(
                        get: { settings.pickupDirection },
                        set: { runtime.setPickupDirection($0) }
                    )) {
                        Text("四周").tag(SubtitleTranslateWire.PickupDirection.around)
                        Text("前方").tag(SubtitleTranslateWire.PickupDirection.ahead)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!runtime.canChangePickupDirection)
                    .accessibilityIdentifier("subtitle-pickup-direction")
                    Text("空闲时记住下次启动方向；字幕运行时提交切换指令。前方模式需面向说话者，侧方抑制程度会随声场变化。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = runtime.pickupDirectionMessage {
                        Text(message).font(.caption).foregroundStyle(Palette.amber)
                    }
                    if runtime.pickupDirectionNeedsRetry {
                        Button("重试收音切换") { runtime.retryPickupDirection() }
                            .accessibilityIdentifier("subtitle-pickup-direction-retry")
                    }
                } }
                Section("本机保存") {
                    Toggle("同时保存音频", isOn: $draft.recordAudio).accessibilityIdentifier("subtitle-save-audio")
                    Text("文本总会保存。音频为处理后的 16 kHz 单声道 WAV，每 60 秒分段；已知断流另起一段，不补静音。约 115 MB/小时，仅存此 App，不自动上传网盘。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("单次时长上限", selection: $draft.maximumSeconds) {
                        Text("30 分钟").tag(1800); Text("60 分钟").tag(3600); Text("120 分钟").tag(7200)
                    }
                    Button("保存字幕设置") {
                        draft.idleSeconds = 0
                        if alwaysOn.activeTask { confirmApply = true }
                        else { saveDraft() }
                    }
                        .accessibilityIdentifier("subtitle-save-settings")
                    if saved { Text("已保存；不会自动开始收音。开始时使用所选音频来源与识别引擎。") .font(.caption).foregroundStyle(Palette.green) }
                    if let error = settings.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                }.disabled(busy || !settings.allowsChanges)
                Section("双击眼镜旋钮 → 字幕") {
                    Text("先读取 → 设置双击字幕 → 再次读取确认。只改双击，保留长按和其他配置。") .font(.caption).foregroundStyle(.secondary)
                    Button("读取眼镜快捷键") { features.refreshSettings() }.disabled(!voice.ready || busy)
                    Button("永久将双击设为字幕") {
                        voice.stop(); runtime.setShortcut(true); features.setDoubleTapSubtitles(true)
                    }.disabled(!voice.ready || busy || !settings.requirements.isEmpty)
                    Text(features.subtitleShortcutStatus).font(.caption).foregroundStyle(features.doubleTapIsSubtitle ? Palette.green : Palette.muted)
                    if let error = features.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                    Toggle("双击启动实时字幕（永久记住）", isOn: Binding(get: { runtime.shortcutEnabled }, set: {
                        if $0 { voice.stop() }; runtime.setShortcut($0)
                    })).disabled(busy || !settings.requirements.isEmpty)
                        .accessibilityIdentifier("subtitle-shortcut-enabled")
                    Text("开启一次后会跨 App 重启保存。眼镜的字幕入口（包括双击和菜单）会按已保存配置直接开始上传与保存；再次双击会停止并保存。App 每次连接眼镜都会核对并恢复双击映射。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("锁屏和正常切到后台时会使用外设后台连接继续工作；若用户从多任务界面强制结束 App，iOS 不保证眼镜能冷启动它。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("恢复原来的双击操作") { runtime.setShortcut(false); features.setDoubleTapSubtitles(false) }
                        .disabled(!voice.ready || busy)
                }.disabled(alwaysOn.enabled)
                Section("实验：延迟诊断") {
                    Toggle("记录分阶段延迟（永久记住）", isOn: Binding(
                        get: { latency.enabled },
                        set: { latency.setEnabled($0) }
                    )).disabled(runtime.active)
                        .accessibilityIdentifier("subtitle-latency-enabled")
                    Text("只记录毫秒、次数和最小/平均/最大值，不记录音频、字幕正文、密钥、原始序号或设备标识。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("由于眼镜包没有可与手机时钟对齐的采集时间戳，只能测启动到首包、包间抖动、App 排队、云端就绪/返回和结果下发；不能伪装成精确的麦克风单向网络延迟。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清空延迟统计", role: .destructive) { latency.reset() }
                        .disabled(runtime.active || latency.sessionCount == 0)
                }
                if !voice.supportsDevice { Text("本地预览不保存密钥、不连接眼镜或转写服务。").font(.caption) }
                if voice.enabled { Button("先关闭 AI 对话待命") { voice.stop() } }
            }
            .navigationTitle("字幕设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                draft = settings.options; settings.refresh()
                draftInputSource = settings.inputSource
                draftInputUID = settings.systemInputUID ?? ""
                draftTranslationEnabled = settings.translationEnabled
                draftShowOnGlasses = settings.showOnGlasses
            }
            .onChange(of: draft.service) { _ in key = ""; saved = false }
            .onChange(of: draft.aliyunModel) { _ in saved = false }
            .translationTask(translationConfiguration) { session in
                #if COMPANION_DEVICE
                do {
                    try await AppleCaptionTranslation.prepare(session: session)
                    translationStatus = "翻译语言包已就绪"
                } catch { translationStatus = "语言包准备失败：\(error.localizedDescription)" }
                #endif
                translationConfiguration = nil
            }
            .confirmationDialog("全天智记正在运行，何时应用新服务设置？", isPresented: $confirmApply) {
                Button("立即应用并重连 ASR") { applyAlwaysOn(.immediately) }
                Button("下一次眼镜语音任务生效") { applyAlwaysOn(.nextTask) }
                Button("取消", role: .cancel) {}
            } message: { Text("立即应用不会重启眼镜采音，但 ASR 重连期间可能产生短暂缺口。") }
        }
    }

    private func applyAlwaysOn(_ policy: AlwaysOnApplyPolicy) {
        saved = alwaysOn.applySpeechSettings(draft, key: key, policy: policy)
        if saved { persistInputSettings(); key = "" }
    }

    private var inputDescription: String {
        switch draftInputSource {
        case .glasses: return "使用眼镜自己的音频流，可选择前方或四周；需要眼镜连接。"
        case .iPhoneMicrophone: return "固定使用 iPhone 内置麦克风；开始时请求录音权限。"
        case .systemMicrophone: return "使用系统当前或指定的外接麦克风，例如 AirPods、有线或 USB 设备；不能录制其他 App 的播放声音。"
        }
    }
    private var translationPair: (source: String, target: String) {
        if draft.language.hasPrefix("zh") {
            return ("zh-CN", "en-US")
        }
        return (draft.language, "zh-CN")
    }
    private var translationPairDescription: String {
        draft.language.hasPrefix("zh") ? "中文语音 → 英文译文。原文会先显示，译文在最终字幕形成后更新。" :
            "英文语音 → 中文译文。原文会先显示，译文在最终字幕形成后更新。"
    }
    private func refreshInputPorts() {
        inputStatus = "正在读取系统麦克风…"
        Task {
            do {
                inputPorts = try await SubtitleMicrophoneInput.availablePorts()
                inputStatus = inputPorts.isEmpty ? "没有可用的录音输入设备。" : "已列出 \(inputPorts.count) 个可用输入；实际路由会在开始时核对。"
            } catch { inputStatus = "无法读取麦克风：\(error.localizedDescription)" }
        }
    }
    private func prepareLocalModel() {
        #if COMPANION_DEVICE
        localModelStatus = "正在准备所选语言的本机模型…"
        Task {
            do {
                try await AppleLocalCaptionASR.prepare(localeIdentifier: draft.language)
                localModelStatus = "本机识别模型已就绪"
            } catch { localModelStatus = "模型不可用：\(error.localizedDescription)" }
        }
        #else
        localModelStatus = "本地预览不准备真机模型。"
        #endif
    }
    private func prepareTranslationLanguages() {
        #if COMPANION_DEVICE
        translationStatus = "正在检查翻译语言包…"
        translationConfiguration = AppleCaptionTranslation.configuration(
            source: translationPair.source, target: translationPair.target)
        #else
        translationStatus = "本地预览不准备真机语言包。"
        #endif
    }
    private func persistInputSettings() {
        settings.saveInputSource(draftInputSource, systemInputUID: draftInputUID.isEmpty ? nil : draftInputUID)
        settings.saveTranslationEnabled(draftTranslationEnabled)
        settings.saveShowOnGlasses(draftShowOnGlasses)
    }
    private func saveDraft() {
        saved = settings.save(draft, key: key)
        if saved { persistInputSettings(); key = "" }
    }
}
