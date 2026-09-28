import SwiftUI
import RayNeoCaptions
import RayNeoProtocol
import Translation
import Combine

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
    @State private var dismissAfterSave = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
    @State private var draftInputSource: SubtitleInputSource = .glasses
    @State private var draftInputUID = ""
    @State private var draftTranslationEnabled = false
    @State private var draftTranslationQuality: SubtitleTranslationQuality = .lowLatency
    @State private var draftShowOnGlasses = true
    @State private var draftDisplayMode: SubtitleDisplayMode = .bilingual
    @State private var draftBilingualOrder: SubtitleBilingualOrder = .sourceFirst
    @State private var draftDisplayRetention: SubtitleDisplayRetention = .untilNextSentence
    @State private var draftShowLiveSourceDuringTranslation = true
    @State private var draftCustomRetentionSeconds = 5.0
    @State private var advancedDisplayExpanded = false
    @State private var inputPorts: [SubtitleMicrophoneInput.Port] = []
    @State private var inputStatus = ""
    @State private var localModelStatus = ""
    @State private var translationStatus = ""
    @State private var preparingTranslationDescription = ""
    @State private var preparingTranslation = false
    @State private var translationPreparationID: UUID?
    @State private var sampleText = ""
    @State private var sampleDetection: LocalSubtitleLanguageDetection.Result?
    @State private var sampleDetectionStatus = ""
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
                    Text("准备模型仅为所选语言下载或检查资源，不会根据麦克风声音自动判断语种。中文与英语需要先选好识别语言。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("实验：用文字样本检查识别语言") {
                        TextField("粘贴一段已经识别的文字（建议至少 20 个字或字母）", text: $sampleText,
                                  axis: .vertical)
                            .lineLimit(3...6)
                            .accessibilityIdentifier("subtitle-language-sample")
                        Button("检测文字语言") {
                            sampleDetection = LocalSubtitleLanguageDetection.detect(sampleText: sampleText)
                            sampleDetectionStatus = sampleDetection == nil
                                ? "样本过短、不够明确，或不是支持的简体中文/英文。繁体中文不会自动映射为 zh-CN；请手动确认语言。当前设置未变。"
                                : "检测完成；需要手动应用后才会更改识别语言。"
                        }
                        .accessibilityIdentifier("subtitle-detect-sample-language")
                        if let result = sampleDetection {
                            LabeledContent("文字语言", value: "\(result.language.name) · 约 \(Int(result.confidence * 100))% 置信度")
                            if result.language == .english {
                                Text(draft.language == "en-GB" || draft.language == "en-US"
                                     ? "文字不能判断英式或美式口音；应用后沿用当前英语地区设置。"
                                     : "文字不能判断英式或美式口音；应用后暂选 English · US，也可以在上方改为 English · UK。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("应用到识别语言") {
                                draft.language = result.suggestedLocale(currentLocale: draft.language)
                                sampleDetectionStatus = "已选择 \(draft.language)；请点击完成或保存字幕设置。"
                            }
                            .accessibilityIdentifier("subtitle-apply-detected-language")
                        }
                        if !sampleDetectionStatus.isEmpty {
                            Text(sampleDetectionStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("这里只判断粘贴文字的语言，不读取麦克风。文字无法判断英式或美式口音；英语地区沿用当前选择。实时收音不会自动切换模型。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.service != .appleLocal {
                        SecureField(settings.hasKey(for: draft) ? "已保存密钥，留空保留" : "填写自己的 API Key", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("subtitle-api-key")
                    }
                }.disabled(busy)
                Section("本地翻译") {
                    Toggle("翻译最终字幕", isOn: $draftTranslationEnabled)
                        .accessibilityIdentifier("subtitle-local-translation")
                        .disabled(busy)
                    Text(translationPairDescription).font(.caption).foregroundStyle(.secondary)
                    Text("“准备翻译语言包”仅检查当前选择的固定语言对与翻译策略，不会从声音中自动判断源语言。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("字幕语言", selection: $draftDisplayMode) {
                        ForEach(SubtitleDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.name).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("subtitle-display-mode")
                    if draftDisplayMode == .bilingual {
                        Picker("中英混合顺序", selection: $draftBilingualOrder) {
                            ForEach(SubtitleBilingualOrder.allCases, id: \.self) { order in
                                Text(order.name).tag(order)
                            }
                        }
                        .accessibilityIdentifier("subtitle-bilingual-order")
                    }
                    Text(draftTranslationEnabled
                         ? "默认在识别中临时显示原文，即使最终选择“只看中文/英文”；译文完成后替换。需要严格单语时，可在产品测试选项中关闭流式原文。"
                         : "翻译关闭时，字幕语言须与识别语言一致；中英混合需要开启翻译。")
                        .font(.caption).foregroundStyle(.secondary)
                    if draftTranslationEnabled {
                        Button(preparingTranslation ? "正在准备翻译语言包…" : "准备翻译语言包") {
                            prepareTranslationLanguages()
                        }
                            .accessibilityIdentifier("subtitle-prepare-translation")
                            .disabled(busy || preparingTranslation)
                        if !translationStatus.isEmpty { Text(translationStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(!settings.allowsChanges)
                Section {
                    DisclosureGroup("实验：翻译与字幕时序（产品测试）", isExpanded: $advancedDisplayExpanded) {
                        Picker("本机翻译策略", selection: $draftTranslationQuality) {
                            ForEach(SubtitleTranslationQuality.allCases, id: \.self) { quality in
                                Text(quality.name).tag(quality)
                            }
                        }
                        .disabled(!draftTranslationEnabled || busy)
                        .accessibilityIdentifier("subtitle-translation-quality")
                        Text(draftTranslationQuality.detail)
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("新一句开始时显示流式原文", isOn: $draftShowLiveSourceDuringTranslation)
                            .accessibilityIdentifier("subtitle-advanced-live-source")
                        Text("开启后，即使只看译文，新一句流式原文也会覆盖上一句译文；本句识别完成后继续保留原文，直到译文返回并替换。关闭后优先保留上一句；首句混合模式仍显示已识别原文。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("最终字幕停留", selection: $draftDisplayRetention) {
                            ForEach(SubtitleDisplayRetention.allCases, id: \.self) { retention in
                                Text(retention.name).tag(retention)
                            }
                        }
                        .accessibilityIdentifier("subtitle-display-retention")
                        if draftDisplayRetention == .custom {
                            HStack {
                                Text("自定义时长")
                                Spacer()
                                Text("\(Int(draftCustomRetentionSeconds)) 秒")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: $draftCustomRetentionSeconds, in: 1...30, step: 1)
                                .accessibilityLabel("最终字幕自定义停留秒数")
                                .accessibilityIdentifier("subtitle-custom-retention-seconds")
                        }
                        Text("停留计时从最终字幕出现时开始；开启流式原文时，新一句会提前替换。选择“直到下一句”则保持最后一句，直到后续可显示的字幕出现。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("恢复显示时序默认值") {
                            draftShowLiveSourceDuringTranslation = true
                            draftDisplayRetention = .untilNextSentence
                            draftCustomRetentionSeconds = 5
                        }
                        .accessibilityIdentifier("subtitle-advanced-reset")
                    }
                } header: {
                    Label("产品测试选项", systemImage: "slider.horizontal.3")
                } footer: {
                    Text("翻译策略会影响译文质量、耗时及设备资源；显示选项只改变字幕何时出现和消失。")
                }
                .disabled(!settings.allowsChanges)
                Section("显示预览") {
                    SubtitleDisplayPreview(language: draft.language,
                                           translationEnabled: draftTranslationEnabled,
                                           mode: draftDisplayMode,
                                           order: draftBilingualOrder,
                                           retention: draftDisplayRetention,
                                           customRetentionSeconds: draftCustomRetentionSeconds,
                                           showLiveSourceDuringTranslation: draftShowLiveSourceDuringTranslation)
                }
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
                    Toggle("同时保存音频", isOn: $draft.recordAudio)
                        .accessibilityIdentifier("subtitle-save-audio")
                        .disabled(busy)
                    Text("文本总会保存。音频为处理后的 16 kHz 单声道 WAV，每 60 秒分段；已知断流另起一段，不补静音。约 115 MB/小时，仅存此 App，不自动上传网盘。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("单次时长上限", selection: $draft.maximumSeconds) {
                        Text("30 分钟").tag(1800); Text("60 分钟").tag(3600); Text("120 分钟").tag(7200)
                    }
                    .disabled(busy)
                    Button("保存字幕设置") {
                        beginSave(dismissOnSuccess: false)
                    }
                        .accessibilityIdentifier("subtitle-save-settings")
                    if saved { Text("已保存；不会自动开始收音。开始时使用所选音频来源与识别引擎。") .font(.caption).foregroundStyle(Palette.green) }
                    if let error = settings.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                }.disabled(!settings.allowsChanges)
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
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { beginSave(dismissOnSuccess: true) }
                    .accessibilityIdentifier("subtitle-settings-done")
            } }
            .onAppear {
                draft = settings.options; draft.idleSeconds = 0; settings.refresh()
                draftInputSource = settings.inputSource
                draftInputUID = settings.systemInputUID ?? ""
                draftTranslationEnabled = settings.translationEnabled
                draftTranslationQuality = settings.translationQuality
                draftShowOnGlasses = settings.showOnGlasses
                draftDisplayMode = settings.translationEnabled ? settings.displayMode : sourceOnlyMode
                draftBilingualOrder = settings.bilingualOrder
                draftDisplayRetention = settings.displayRetention
                draftShowLiveSourceDuringTranslation = settings.showLiveSourceDuringTranslation
                draftCustomRetentionSeconds = settings.customRetentionSeconds
            }
            .onChange(of: draft.service) { _ in key = ""; saved = false }
            .onChange(of: draft) { _ in saved = false }
            .onChange(of: key) { newValue in if !newValue.isEmpty { saved = false } }
            .onChange(of: draftInputSource) { _ in saved = false }
            .onChange(of: draftInputUID) { _ in saved = false }
            .onChange(of: draftTranslationEnabled) { enabled in
                saved = false
                if !enabled { draftDisplayMode = sourceOnlyMode }
            }
            .onChange(of: draftTranslationQuality) { _ in saved = false; translationStatus = "" }
            .onChange(of: draft.language) { _ in
                localModelStatus = ""
                translationStatus = ""
                if !draftTranslationEnabled { draftDisplayMode = sourceOnlyMode }
            }
            .onChange(of: draftShowOnGlasses) { _ in saved = false }
            .onChange(of: draftDisplayMode) { _ in saved = false }
            .onChange(of: draftBilingualOrder) { _ in saved = false }
            .onChange(of: draftDisplayRetention) { _ in saved = false }
            .onChange(of: sampleText) { _ in sampleDetection = nil; sampleDetectionStatus = "" }
            .onChange(of: draftShowLiveSourceDuringTranslation) { _ in saved = false }
            .onChange(of: draftCustomRetentionSeconds) { _ in saved = false }
            .translationTask(translationConfiguration) { session in
                #if COMPANION_DEVICE
                guard let requestID = translationPreparationID else { return }
                let requested = preparingTranslationDescription
                do {
                    try await AppleCaptionTranslation.prepare(session: session)
                    guard translationPreparationID == requestID else { return }
                    let current = "\(translationPair.source) → \(translationPair.target)（\(draftTranslationQuality.name)）"
                    translationStatus = requested == current
                        ? "\(requested) 语言包已就绪；该操作不会识别麦克风语种。"
                        : "\(requested) 语言包已就绪；当前已选 \(current)，请为当前配置重新准备。"
                } catch {
                    guard translationPreparationID == requestID else { return }
                    translationStatus = "\(requested) 语言包准备失败：\(error.localizedDescription)"
                }
                guard translationPreparationID == requestID else { return }
                #endif
                translationConfiguration = nil
                preparingTranslation = false
                translationPreparationID = nil
            }
            .confirmationDialog("全天智记正在运行，何时应用新服务设置？", isPresented: $confirmApply) {
                Button("立即应用并重连 ASR") { applyAlwaysOn(.immediately) }
                Button("下一次眼镜语音任务生效") { applyAlwaysOn(.nextTask) }
                Button("取消", role: .cancel) { dismissAfterSave = false }
            } message: { Text("立即应用不会重启眼镜采音，但 ASR 重连期间可能产生短暂缺口。") }
            .alert("字幕设置未保存", isPresented: $showSaveError) {
                Button("知道了", role: .cancel) {}
            } message: { Text(saveErrorMessage) }
        }
    }

    private func beginSave(dismissOnSuccess: Bool) {
        dismissAfterSave = dismissOnSuccess
        saved = false
        guard validateDisplaySelection() else {
            dismissAfterSave = false
            return
        }
        if !hasSpeechOrInputChanges {
            saved = !hasDisplayPreferenceChanges || settings.saveDisplayPreferences(
                mode: draftDisplayMode, order: draftBilingualOrder, retention: draftDisplayRetention,
                showLiveSourceDuringTranslation: draftShowLiveSourceDuringTranslation,
                customRetentionSeconds: draftCustomRetentionSeconds)
            finishSave()
        } else if alwaysOn.activeTask && !busy && settings.allowsChanges {
            confirmApply = true
        } else {
            saveDraft()
        }
    }

    private var sourceOnlyMode: SubtitleDisplayMode {
        draft.language.hasPrefix("zh") ? .chineseOnly : .englishOnly
    }

    private var hasDisplayPreferenceChanges: Bool {
        draftDisplayMode != settings.displayMode || draftBilingualOrder != settings.bilingualOrder ||
            draftDisplayRetention != settings.displayRetention ||
            draftShowLiveSourceDuringTranslation != settings.showLiveSourceDuringTranslation ||
            draftCustomRetentionSeconds != settings.customRetentionSeconds
    }

    private var hasSpeechOrInputChanges: Bool {
        var requested = draft
        var stored = settings.options
        requested.idleSeconds = 0
        stored.idleSeconds = 0
        return requested != stored || !key.isEmpty || draftInputSource != settings.inputSource ||
            (draftInputSource == .systemMicrophone && draftInputUID != (settings.systemInputUID ?? "")) ||
            draftTranslationEnabled != settings.translationEnabled || draftShowOnGlasses != settings.showOnGlasses ||
            draftTranslationQuality != settings.translationQuality
    }

    private func validateDisplaySelection() -> Bool {
        guard draftTranslationEnabled || draftDisplayMode == sourceOnlyMode else {
            saveErrorMessage = draft.language.hasPrefix("zh")
                ? "当前识别语言是中文。只看英文或中英混合需要开启翻译；也可选择只看中文。"
                : "当前识别语言是英文。只看中文或中英混合需要开启翻译；也可选择只看英文。"
            showSaveError = true
            return false
        }
        return true
    }

    private func applyAlwaysOn(_ policy: AlwaysOnApplyPolicy) {
        saved = alwaysOn.applySpeechSettings(draft, key: key, policy: policy)
        if saved { saved = persistInputSettings() }
        finishSave()
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
        draft.language.hasPrefix("zh") ? "中文语音 → 英文译文。译文在一句话结束后生成。" :
            "英文语音 → 中文译文。译文在一句话结束后生成。"
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
        let selectedLanguage = draft.language
        localModelStatus = "正在准备 \(selectedLanguage) 本机识别模型…"
        Task {
            do {
                let matchedLanguage = await AppleLocalCaptionASR.matchedLocaleIdentifier(
                    localeIdentifier: selectedLanguage)
                try await AppleLocalCaptionASR.prepare(localeIdentifier: selectedLanguage)
                let prepared = "\(selectedLanguage) 模型已就绪；系统实际匹配 \(matchedLanguage ?? selectedLanguage)。"
                localModelStatus = draft.language == selectedLanguage
                    ? prepared + "不检测麦克风语种。"
                    : prepared + "当前已选 \(draft.language)，请为当前语言重新准备。"
            } catch { localModelStatus = "模型不可用：\(error.localizedDescription)" }
        }
        #else
        localModelStatus = "本地预览不准备真机模型。"
        #endif
    }
    private func prepareTranslationLanguages() {
        #if COMPANION_DEVICE
        guard !preparingTranslation else { return }
        preparingTranslation = true
        translationPreparationID = UUID()
        let pair = translationPair
        preparingTranslationDescription = "\(pair.source) → \(pair.target)（\(draftTranslationQuality.name)）"
        translationStatus = "正在准备 \(preparingTranslationDescription) 语言包…"
        translationConfiguration = AppleCaptionTranslation.configuration(
            source: pair.source, target: pair.target, quality: draftTranslationQuality)
        #else
        translationStatus = "本地预览不准备真机语言包。"
        #endif
    }
    private func persistInputSettings() -> Bool {
        settings.saveInputSource(draftInputSource, systemInputUID: draftInputUID.isEmpty ? nil : draftInputUID)
        guard settings.error == nil else { return false }
        settings.saveTranslationEnabled(draftTranslationEnabled)
        guard settings.error == nil else { return false }
        settings.saveTranslationQuality(draftTranslationQuality)
        guard settings.error == nil else { return false }
        settings.saveShowOnGlasses(draftShowOnGlasses)
        guard settings.error == nil else { return false }
        return settings.saveDisplayPreferences(mode: draftDisplayMode, order: draftBilingualOrder,
                                               retention: draftDisplayRetention,
                                               showLiveSourceDuringTranslation: draftShowLiveSourceDuringTranslation,
                                               customRetentionSeconds: draftCustomRetentionSeconds)
    }
    private func saveDraft() {
        saved = settings.save(draft, key: key)
        if saved { saved = persistInputSettings() }
        finishSave()
    }
    private func finishSave() {
        if saved {
            key = ""
            if dismissAfterSave { dismiss() }
        } else {
            saveErrorMessage = settings.error ?? alwaysOn.error ?? "请检查字幕设置后重试。"
            showSaveError = true
        }
        dismissAfterSave = false
    }
}

/// Local sample-only preview. It follows the display rules but never opens an
/// audio input, recognition provider, or TranslationSession.
private struct SubtitleDisplayPreview: View {
    let language: String
    let translationEnabled: Bool
    let mode: SubtitleDisplayMode
    let order: SubtitleBilingualOrder
    let retention: SubtitleDisplayRetention
    let customRetentionSeconds: Double
    let showLiveSourceDuringTranslation: Bool

    private enum Scenario: String, CaseIterable {
        case normal, rapidTurns, secondTranslationFails

        var name: String {
            switch self {
            case .normal: return "连续对话"
            case .rapidTurns: return "快速插话"
            case .secondTranslationFails: return "译文失败"
            }
        }
    }

    private struct PreviewState {
        let caption: String
        let status: String
        let explanation: String
        let isPartial: Bool
    }

    @State private var scenario: Scenario = .normal
    @State private var playhead: Double = 8.6
    @State private var playing = false
    @State private var lastTick: Date?
    private var retentionSeconds: Double? {
        retention == .custom ? min(30, max(1, customRetentionSeconds)) : retention.seconds
    }
    private var duration: Double { max(29, 23 + (retentionSeconds ?? 0)) }

    var body: some View {
        let state = previewState(at: playhead)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("手机字幕画面", systemImage: "iphone.gen3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("示例文字")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Picker("预览情景", selection: $scenario) {
                ForEach(Scenario.allCases, id: \.self) { item in
                    Text(item.name).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!translationEnabled)
            .accessibilityIdentifier("subtitle-preview-scenario")
            if !translationEnabled && mode != sourceOnlyMode {
                Text("翻译关闭时无法保存此语言模式。预览按识别语言显示；请开启翻译或选择\(sourceOnlyMode.name)。")
                    .font(.caption)
                    .foregroundStyle(Palette.amber)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "text.bubble.fill")
                    Text("此刻的字幕")
                    Spacer()
                    Text(state.status)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))
                Text(state.caption.isEmpty ? " " : state.caption)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(state.isPartial ? Color.green : .white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                    .accessibilityIdentifier("subtitle-preview-caption")
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.08, green: 0.13, blue: 0.18), in: RoundedRectangle(cornerRadius: 16))

            Text(state.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("subtitle-preview-phase")
            Slider(value: $playhead, in: 0...duration)
                .accessibilityLabel("预览进度")
                .accessibilityIdentifier("subtitle-preview-scrub")
            HStack {
                Text(timeLabel(playhead))
                Spacer()
                Text(timeLabel(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Label(playing ? "暂停" : "播放", systemImage: playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("subtitle-preview-play-pause")
                Button {
                    playhead = 0
                    playing = true
                    lastTick = Date()
                } label: {
                    Label("从头播放", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("subtitle-preview-replay")
            }
            Text("示例演示临时原文、译文等待、下一句覆盖和停留时间。翻译返回时间是固定示例，不代表低延迟或高保真策略的实测耗时。眼镜排版以真机为准；不会启动麦克风、转写或翻译服务。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { tick in
            guard playing else { return }
            let elapsed = max(0, min(0.25, lastTick.map { tick.timeIntervalSince($0) } ?? 0.1))
            lastTick = tick
            playhead = min(duration, playhead + elapsed)
            if playhead >= duration { playing = false; lastTick = nil }
        }
        .onChange(of: duration) { newDuration in
            playhead = min(playhead, newDuration)
            if playhead >= newDuration { playing = false; lastTick = nil }
        }
    }

    private var sourceIsChinese: Bool { language.lowercased().hasPrefix("zh") }
    private var sourceOnlyMode: SubtitleDisplayMode { sourceIsChinese ? .chineseOnly : .englishOnly }
    private var effectiveMode: SubtitleDisplayMode { translationEnabled ? mode : sourceOnlyMode }
    private var sourceOnly: Bool { effectiveMode == sourceOnlyMode }
    private var bilingual: Bool { effectiveMode == .bilingual }

    private var firstSource: String {
        sourceIsChinese
            ? "今天我们沿着河边慢慢走，前面的路口有一家刚开门的书店。"
            : "Today we are walking slowly along the river, and a bookstore has just opened at the next corner."
    }
    private var firstTranslation: String {
        sourceIsChinese
            ? "Today we are walking slowly along the river, and a bookstore has just opened at the next corner."
            : "今天我们沿着河边慢慢走，前面的路口有一家刚开门的书店。"
    }
    private var secondSource: String {
        sourceIsChinese ? "等一下，左边那辆车正在转弯。" : "Wait, the car on the left is turning."
    }
    private var secondTranslation: String {
        sourceIsChinese ? "Wait, the car on the left is turning." : "等一下，左边那辆车正在转弯。"
    }
    private var thirdSource: String {
        sourceIsChinese ? "好，我已经看到了，我们从后面绕过去。" :
            "Okay, I see it now. Let's go around behind it."
    }
    private var thirdTranslation: String {
        sourceIsChinese ? "Okay, I see it now. Let's go around behind it." :
            "好，我已经看到了，我们从后面绕过去。"
    }

    private func previewState(at time: Double) -> PreviewState {
        if time < 0.8 {
            return PreviewState(caption: "", status: "待播放", explanation: "播放或拖动进度，查看长句识别、翻译延迟及下一句切换。", isPartial: false)
        }
        if time < 6 {
            let caption = sourceOnly || bilingual || showLiveSourceDuringTranslation
                ? partial(firstSource, progress: (time - 0.8) / 5.2) : ""
            return PreviewState(caption: caption, status: caption.isEmpty ? "等待译文" : "临时识别",
                                explanation: "第一位说话者说出较长的句子；临时识别会逐步修订。", isPartial: !caption.isEmpty)
        }
        if time < 8.4 {
            if sourceOnly {
                return finalized(firstSource, completedAt: 6, now: time,
                                 explanation: "第一句识别完成；所选语言就是识别原文。")
            }
            let caption = bilingual || showLiveSourceDuringTranslation ? firstSource : ""
            return PreviewState(caption: caption, status: caption.isEmpty ? "等待译文" : "翻译中",
                                explanation: caption.isEmpty
                                    ? "第一句已识别，译文还未生成；当前设置等待译文。"
                                    : "第一句已识别，译文还未生成；本句完整原文继续显示。",
                                isPartial: false)
        }
        let firstCompleted = composed(source: firstSource, translation: firstTranslation)
        if time < 10 {
            return sourceOnly
                ? finalized(firstSource, completedAt: 6, now: time,
                            explanation: "第一句已完成，按所选停留时间显示。")
                : finalized(firstCompleted, completedAt: 8.4, now: time,
                            explanation: "第一句译文生成，按所选语言和混合顺序显示。")
        }
        if time < 14 {
            if sourceOnly || showLiveSourceDuringTranslation {
                return PreviewState(caption: partial(secondSource, progress: (time - 10) / 4),
                                    status: "临时识别",
                                    explanation: "第二位说话者开始；新一句原文逐步覆盖上一句译文。", isPartial: true)
            }
            return finalized(firstCompleted, completedAt: 8.4, now: time,
                             explanation: "第二位说话者开始；当前模式保留上一句，等待新译文。")
        }
        if time < 16.4 {
            return sourceOnly || showLiveSourceDuringTranslation
                ? finalized(secondSource, completedAt: 14, now: time,
                            explanation: "第二句识别完成；本句原文保留到译文返回。",
                            awaitingTranslation: !sourceOnly)
                : finalized(firstCompleted, completedAt: 8.4, now: time,
                            explanation: "第二句已识别，新译文仍在生成；上一句继续停留或到时清空。")
        }
        if scenario == .rapidTurns && time >= 17.4 {
            let secondCompleted = composed(source: secondSource, translation: secondTranslation)
            if time < 20.4 {
                if sourceOnly || showLiveSourceDuringTranslation {
                    return PreviewState(caption: partial(thirdSource, progress: (time - 17.4) / 3),
                                        status: "临时识别",
                                        explanation: "第三位说话者很快插话；原文立即更新，而非等待整句翻译。",
                                        isPartial: true)
                }
                return finalized(secondCompleted, completedAt: 16.4, now: time,
                                 explanation: "快速插话发生；当前设置继续显示上一句译文。")
            }
            if time < 22.4 {
                return sourceOnly || showLiveSourceDuringTranslation
                    ? finalized(thirdSource, completedAt: 20.4, now: time,
                                explanation: "第三句已识别，原文保留直到译文返回。",
                                awaitingTranslation: !sourceOnly)
                    : finalized(secondCompleted, completedAt: 16.4, now: time,
                                explanation: "第三句译文生成中；上一句仍按停留时间显示。")
            }
            return sourceOnly
                ? finalized(thirdSource, completedAt: 20.4, now: time,
                            explanation: "第三句原文按停留时间显示。")
                : finalized(composed(source: thirdSource, translation: thirdTranslation),
                            completedAt: 22.4, now: time,
                            explanation: "第三句译文返回；立即替换暂显原文，开始最终字幕停留计时。")
        }
        if sourceOnly {
            return finalized(secondSource, completedAt: 14, now: time,
                             explanation: scenario == .secondTranslationFails && translationEnabled
                                ? "第二句翻译失败；所选识别原文仍正常显示。"
                                : "第二句识别原文继续显示，直到下一句或停留时间结束。")
        }
        if scenario == .secondTranslationFails {
            let fallback = bilingual ? secondSource :
                (effectiveMode == .chineseOnly ? "本句翻译暂不可用" : "Translation unavailable")
            return finalized(fallback, completedAt: 16.4, now: time,
                             explanation: bilingual
                                ? "第二句翻译失败；混合模式只显示已识别原文。"
                                : (showLiveSourceDuringTranslation
                                   ? "第二句翻译失败；临时原文结束后，换成所选语言的失败提示。"
                                   : "第二句翻译失败；仅用所选语言显示失败提示。"))
        }
        return finalized(composed(source: secondSource, translation: secondTranslation),
                         completedAt: 16.4, now: time,
                         explanation: "第二句译文已生成；可继续拖动观察 3、5、10 秒清空或持续显示。")
    }

    private func finalized(_ caption: String, completedAt: Double, now: Double,
                           explanation: String, awaitingTranslation: Bool = false) -> PreviewState {
        if !awaitingTranslation, let seconds = retentionSeconds, now >= completedAt + seconds {
            return PreviewState(caption: "", status: "已清空",
                                explanation: "最终字幕显示 \(Int(seconds)) 秒后清空；下一句生成时会重新显示。",
                                isPartial: false)
        }
        return PreviewState(caption: caption, status: awaitingTranslation ? "翻译中" : "最终字幕",
                            explanation: explanation, isPartial: false)
    }

    private func composed(source: String, translation: String) -> String {
        if sourceOnly { return source }
        if bilingual {
            return order == .sourceFirst ? source + "\n" + translation : translation + "\n" + source
        }
        return translation
    }

    private func partial(_ text: String, progress: Double) -> String {
        let fraction = max(0.05, min(1, progress))
        if sourceIsChinese {
            let characters = Array(text)
            return String(characters.prefix(max(1, Int(ceil(Double(characters.count) * fraction)))))
        }
        let words = text.split(separator: " ")
        return words.prefix(max(1, Int(ceil(Double(words.count) * fraction)))).joined(separator: " ")
    }

    private func togglePlayback() {
        if playhead >= duration {
            playhead = 0
            playing = true
        } else { playing.toggle() }
        lastTick = playing ? Date() : nil
    }

    private func timeLabel(_ value: Double) -> String {
        let whole = Int(value)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
