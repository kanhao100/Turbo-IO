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
    @State private var draftDisplayLayout: SubtitleDisplayLayout = .rolling
    @State private var draftRollingConfiguration = CaptionRollingConfiguration()
    @State private var draftBilingualOrder: SubtitleBilingualOrder = .sourceFirst
    @State private var draftDisplayRetention: SubtitleDisplayRetention = .untilNextSentence
    @State private var draftShowLiveSourceDuringTranslation = true
    @State private var draftCustomRetentionSeconds = 5.0
    @State private var draftPartialUpdateIntervalSeconds = 0.0
    @State private var draftNextSentenceTakeoverDelaySeconds = 0.0
    @State private var draftMinimumSourceVisibleSeconds = 0.0
    @State private var draftTranslationRevealDelaySeconds = 0.0
    @State private var draftTranslationMinimumVisibleSeconds = 1.5
    @State private var draftLensUpdateIntervalSeconds = 0.5
    @State private var retentionMilliseconds = "5000"
    @State private var partialMilliseconds = "0"
    @State private var takeoverMilliseconds = "0"
    @State private var sourceMilliseconds = "0"
    @State private var revealMilliseconds = "0"
    @State private var translationHoldMilliseconds = "1500"
    @State private var lensMilliseconds = "500"
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
                    if draftDisplayMode == .bilingual && draftDisplayLayout == .sentence {
                        Picker("中英混合顺序", selection: $draftBilingualOrder) {
                            ForEach(SubtitleBilingualOrder.allCases, id: \.self) { order in
                                Text(order.name).tag(order)
                            }
                        }
                        .accessibilityIdentifier("subtitle-bilingual-order")
                    }
                    Text(draftTranslationEnabled
                         ? (draftDisplayLayout == .rolling
                            ? "滚动分区让原文与译文各自向上滚动。后续原文继续显示，较早片段的译文返回后仍会进入译文区。单语模式使用全部五行。"
                            : "默认在识别中临时显示原文，即使最终选择“只看中文/英文”；译文完成后替换。需要严格单语时，可在产品测试选项中关闭流式原文。")
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
                    DisclosureGroup("字幕产品工作台", isExpanded: $advancedDisplayExpanded) {
                        Picker("显示方式", selection: $draftDisplayLayout) {
                            ForEach(SubtitleDisplayLayout.allCases, id: \.self) { layout in
                                Text(layout.name).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("subtitle-display-layout")
                        if draftDisplayLayout == .rolling {
                            Stepper("原文 \(draftRollingConfiguration.sourceLines) 行 · 译文 \(draftRollingConfiguration.translationLines) 行",
                                    value: $draftRollingConfiguration.sourceLines, in: 1...4)
                                .accessibilityIdentifier("subtitle-rolling-source-lines")
                            Picker("滚动步长", selection: $draftRollingConfiguration.scrollUnit) {
                                Text("按行滚动").tag(CaptionScrollUnit.line)
                                Text("按词滚动（实验）").tag(CaptionScrollUnit.word)
                            }
                            .accessibilityIdentifier("subtitle-rolling-scroll-unit")
                            Stepper("每行宽度 \(draftRollingConfiguration.columns)",
                                    value: $draftRollingConfiguration.columns, in: 16...40)
                                .accessibilityIdentifier("subtitle-rolling-columns")
                            Stepper("英文行宽 \(String(format: "%.1f", Double(draftRollingConfiguration.englishWidthPercent) / 100)) 倍",
                                    value: $draftRollingConfiguration.englishWidthPercent, in: 100...200, step: 10)
                                .accessibilityIdentifier("subtitle-rolling-english-width")
                            Text("推荐原文 3 行、译文 2 行，每行宽度 40，英文行宽 1.4 倍，按行滚动。宽度 40 约容纳 20 个汉字或 56 个普通英文字符；英文倍率调大可放入更多英文，中文容量不变。实际换行还受镜片字体影响；过大时眼镜可能再次换行，请按实测校准。按词滚动用于比较文本窗口变化，不代表眼镜支持平滑动画。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("按段替换保留原有显示方式；新段接管延迟、原文最短可见与双语顺序只在此模式生效。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
                            .disabled(draftDisplayLayout == .rolling)
                            .accessibilityIdentifier("subtitle-advanced-live-source")
                        Text(draftDisplayLayout == .rolling
                             ? "滚动分区持续更新原文区并保留译文区；此替换选项不生效。"
                             : "开启后，即使只看译文，新一句流式原文也会覆盖上一句译文；本句识别完成后继续保留原文，直到译文返回并替换。关闭后优先保留上一句；首句混合模式仍显示已识别原文。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("识别与换句")
                            .font(.subheadline.weight(.semibold))
                        SubtitleMillisecondControl(title: "流式原文更新间隔", detail: "0 ms 表示收到可显示的临时识别就更新；较大的值会合并频繁修订。每句第一段仍立即显示。", range: 0...1000,
                                                     seconds: $draftPartialUpdateIntervalSeconds,
                                                     milliseconds: $partialMilliseconds,
                                                     identifier: "subtitle-partial-update-ms")
                            .disabled(!draftCanShowAnySourceBeforeTranslation)
                        SubtitleMillisecondControl(title: "新一句接管延迟", detail: "从新一句第一段临时识别开始计时；到时显示该句最新原文。0 ms 表示立即接管。", range: 0...1000,
                                                     seconds: $draftNextSentenceTakeoverDelaySeconds,
                                                     milliseconds: $takeoverMilliseconds,
                                                     identifier: "subtitle-next-takeover-ms")
                            .disabled(draftDisplayLayout == .rolling || !draftCanShowLaterSourceBeforeTranslation)
                        if draftDisplayLayout == .sentence && !draftCanShowLaterSourceBeforeTranslation {
                            Text(draftDisplayMode == .bilingual && draftTranslationEnabled
                                 ? "关闭流式原文时，混合模式只在首句暂显原文；后续换句接管参数不生效。"
                                 : "当前只看译文且关闭了流式原文；识别中的更新与换句接管参数不会影响画面。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(draftDisplayLayout == .rolling ? "译文进入窗口" : "译文替换")
                            .font(.subheadline.weight(.semibold))
                        SubtitleMillisecondControl(title: "原文最短可见", detail: "从该句完整原文出现开始计时，译文不会提前取代它。0 ms 不额外等待。", range: 0...3000,
                                                     seconds: $draftMinimumSourceVisibleSeconds,
                                                     milliseconds: $sourceMilliseconds,
                                                     identifier: "subtitle-source-minimum-ms")
                            .disabled(draftDisplayLayout == .rolling || !draftNeedsTranslationDisplay || !draftCanShowAnySourceBeforeTranslation)
                        SubtitleMillisecondControl(title: "译文就绪后延迟", detail: draftDisplayLayout == .rolling
                                                     ? "翻译返回后额外等待，再排入译文区；原文继续独立更新。"
                                                     : "翻译返回后额外等待。实际替换时间取“原文最短可见”和此项两个截止时间中较晚者。", range: 0...3000,
                                                     seconds: $draftTranslationRevealDelaySeconds,
                                                     milliseconds: $revealMilliseconds,
                                                     identifier: "subtitle-translation-reveal-ms")
                            .disabled(!draftNeedsTranslationDisplay)
                        SubtitleMillisecondControl(title: "译文最短停留", detail: "滚动分区每次更新译文后，至少保留这段时间再推进下一条；眼镜连接时从成功发送开始计时。0 ms 不额外等待。", range: 0...5000,
                                                     seconds: $draftTranslationMinimumVisibleSeconds,
                                                     milliseconds: $translationHoldMilliseconds,
                                                     identifier: "subtitle-translation-hold-ms")
                            .disabled(draftDisplayLayout != .rolling || !draftNeedsTranslationDisplay)
                        if draftDisplayLayout == .rolling {
                            Text("原文和译文独立滚动，不需要等待原文最短可见时间；译文就绪后延迟仍控制进入译文区的时间。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !draftNeedsTranslationDisplay {
                            Text("当前显示模式只看识别原文，译文替换参数暂不生效。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !draftCanShowAnySourceBeforeTranslation {
                            Text("当前不显示临时原文，“原文最短可见”暂不生效；译文就绪后延迟仍生效。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if !draftShowLiveSourceDuringTranslation && draftDisplayMode == .bilingual {
                            Text("混合模式关闭流式原文后，“原文最短可见”只影响首句；后续句子等待译文。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("完成与镜片")
                            .font(.subheadline.weight(.semibold))
                        Picker("最终字幕停留", selection: $draftDisplayRetention) {
                            ForEach(SubtitleDisplayRetention.allCases, id: \.self) { retention in
                                Text(retention.name).tag(retention)
                            }
                        }
                        .accessibilityIdentifier("subtitle-display-retention")
                        if draftDisplayRetention == .custom {
                            SubtitleMillisecondControl(title: "最终字幕停留", detail: "0 ms 表示手机最终字幕尽快清空；镜片仍需先送最终内容再送清空指令。一直保留请选“直到下一句”。", range: 0...30000,
                                                         seconds: $draftCustomRetentionSeconds,
                                                         milliseconds: $retentionMilliseconds,
                                                         identifier: "subtitle-custom-retention-ms")
                        }
                        SubtitleMillisecondControl(title: "眼镜字幕最短发送间隔", detail: "眼镜通信保持至少 500 ms 间隔；调高可减少连续更新，但会让镜片字幕更慢。", range: 500...2000,
                                                     seconds: $draftLensUpdateIntervalSeconds,
                                                     milliseconds: $lensMilliseconds,
                                                     identifier: "subtitle-lens-update-ms")
                            .disabled(draftInputSource != .glasses && !draftShowOnGlasses)
                        if draftInputSource != .glasses && !draftShowOnGlasses {
                            Text("当前只在手机显示；镜片发送间隔将在启用眼镜显示时生效。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(draftDisplayLayout == .rolling
                             ? "滚动内容在新内容进入各自区域时向上移。选择“直到下一句”持续保留历史；限时停留只在识别结束且待显示译文处理完后，从静默开始计时。"
                             : "停留计时从最终字幕出现时开始；开启流式原文时，新一句会提前替换。选择“直到下一句”则保持最后一句，直到后续可显示的字幕出现。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("恢复推荐显示设置") {
                            draftDisplayLayout = .rolling
                            draftRollingConfiguration = CaptionRollingConfiguration()
                            draftBilingualOrder = .sourceFirst
                            draftTranslationQuality = .lowLatency
                            draftShowLiveSourceDuringTranslation = true
                            draftDisplayRetention = .untilNextSentence
                            setTimingDefaults()
                        }
                        .accessibilityIdentifier("subtitle-advanced-reset")
                    }
                } header: {
                    Label("产品测试选项", systemImage: "slider.horizontal.3")
                } footer: {
                    Text("毫秒输入可精确设定到 1 ms，滑杆可连续拖动。实际出现时间受识别、翻译、iOS 调度及眼镜通信影响；手机 0 ms 停留可能只闪现一帧，镜片仍需先发送最终内容再清空，且两次发送至少间隔 500 ms。")
                }
                .disabled(!settings.allowsChanges)
                Section("显示预览") {
                    SubtitleDisplayPreview(language: draft.language,
                                           translationEnabled: draftTranslationEnabled,
                                           mode: draftDisplayMode,
                                           displayLayout: draftDisplayLayout,
                                           rollingConfiguration: draftRollingConfiguration,
                                           order: draftBilingualOrder,
                                           retention: draftDisplayRetention,
                                           customRetentionSeconds: draftCustomRetentionSeconds,
                                           showLiveSourceDuringTranslation: draftShowLiveSourceDuringTranslation,
                                           partialUpdateIntervalSeconds: draftPartialUpdateIntervalSeconds,
                                           nextSentenceTakeoverDelaySeconds: draftNextSentenceTakeoverDelaySeconds,
                                           minimumSourceVisibleSeconds: draftMinimumSourceVisibleSeconds,
                                           translationRevealDelaySeconds: draftTranslationRevealDelaySeconds,
                                           translationMinimumVisibleSeconds: draftTranslationMinimumVisibleSeconds,
                                           lensUpdateIntervalSeconds: draftLensUpdateIntervalSeconds)
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
                draftDisplayLayout = settings.displayLayout
                draftRollingConfiguration = settings.rollingConfiguration
                draftBilingualOrder = settings.bilingualOrder
                draftDisplayRetention = settings.displayRetention
                draftShowLiveSourceDuringTranslation = settings.showLiveSourceDuringTranslation
                draftCustomRetentionSeconds = settings.customRetentionSeconds
                draftPartialUpdateIntervalSeconds = settings.partialUpdateIntervalSeconds
                draftNextSentenceTakeoverDelaySeconds = settings.nextSentenceTakeoverDelaySeconds
                draftMinimumSourceVisibleSeconds = settings.minimumSourceVisibleSeconds
                draftTranslationRevealDelaySeconds = settings.translationRevealDelaySeconds
                draftTranslationMinimumVisibleSeconds = settings.translationMinimumVisibleSeconds
                draftLensUpdateIntervalSeconds = settings.lensUpdateIntervalSeconds
                refreshTimingTexts()
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
            .onChange(of: draftDisplayLayout) { _ in saved = false }
            .onChange(of: draftRollingConfiguration) { _ in saved = false }
            .onChange(of: draftBilingualOrder) { _ in saved = false }
            .onChange(of: draftDisplayRetention) { _ in saved = false }
            .onChange(of: sampleText) { _ in sampleDetection = nil; sampleDetectionStatus = "" }
            .onChange(of: draftShowLiveSourceDuringTranslation) { _ in saved = false }
            .onChange(of: draftCustomRetentionSeconds) { _ in saved = false }
            .onChange(of: draftPartialUpdateIntervalSeconds) { _ in saved = false }
            .onChange(of: draftNextSentenceTakeoverDelaySeconds) { _ in saved = false }
            .onChange(of: draftMinimumSourceVisibleSeconds) { _ in saved = false }
            .onChange(of: draftTranslationRevealDelaySeconds) { _ in saved = false }
            .onChange(of: draftTranslationMinimumVisibleSeconds) { _ in saved = false }
            .onChange(of: draftLensUpdateIntervalSeconds) { _ in saved = false }
            .onChange(of: retentionMilliseconds) { _ in saved = false }
            .onChange(of: partialMilliseconds) { _ in saved = false }
            .onChange(of: takeoverMilliseconds) { _ in saved = false }
            .onChange(of: sourceMilliseconds) { _ in saved = false }
            .onChange(of: revealMilliseconds) { _ in saved = false }
            .onChange(of: translationHoldMilliseconds) { _ in saved = false }
            .onChange(of: lensMilliseconds) { _ in saved = false }
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
        guard validateTimingInputs() else {
            dismissAfterSave = false
            return
        }
        if !hasSpeechOrInputChanges {
            saved = !hasDisplayPreferenceChanges || settings.saveDisplayPreferences(
                mode: draftDisplayMode, order: draftBilingualOrder, retention: draftDisplayRetention,
                showLiveSourceDuringTranslation: draftShowLiveSourceDuringTranslation,
                customRetentionSeconds: draftCustomRetentionSeconds,
                partialUpdateIntervalSeconds: draftPartialUpdateIntervalSeconds,
                nextSentenceTakeoverDelaySeconds: draftNextSentenceTakeoverDelaySeconds,
                minimumSourceVisibleSeconds: draftMinimumSourceVisibleSeconds,
                translationRevealDelaySeconds: draftTranslationRevealDelaySeconds,
                translationMinimumVisibleSeconds: draftTranslationMinimumVisibleSeconds,
                lensUpdateIntervalSeconds: draftLensUpdateIntervalSeconds,
                displayLayout: draftDisplayLayout,
                rollingConfiguration: draftRollingConfiguration)
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
    private var draftNeedsTranslationDisplay: Bool {
        draftTranslationEnabled && draftDisplayMode != sourceOnlyMode
    }
    private var draftCanShowAnySourceBeforeTranslation: Bool {
        if draftDisplayLayout == .rolling { return !draftNeedsTranslationDisplay || draftDisplayMode == .bilingual }
        return !draftNeedsTranslationDisplay || draftDisplayMode == .bilingual || draftShowLiveSourceDuringTranslation
    }
    private var draftCanShowLaterSourceBeforeTranslation: Bool {
        if draftDisplayLayout == .rolling { return false }
        return !draftNeedsTranslationDisplay || draftShowLiveSourceDuringTranslation
    }

    private var hasDisplayPreferenceChanges: Bool {
        draftDisplayMode != settings.displayMode || draftBilingualOrder != settings.bilingualOrder ||
            draftDisplayLayout != settings.displayLayout || draftRollingConfiguration != settings.rollingConfiguration ||
            draftDisplayRetention != settings.displayRetention ||
            draftShowLiveSourceDuringTranslation != settings.showLiveSourceDuringTranslation ||
            draftCustomRetentionSeconds != settings.customRetentionSeconds ||
            draftPartialUpdateIntervalSeconds != settings.partialUpdateIntervalSeconds ||
            draftNextSentenceTakeoverDelaySeconds != settings.nextSentenceTakeoverDelaySeconds ||
            draftMinimumSourceVisibleSeconds != settings.minimumSourceVisibleSeconds ||
            draftTranslationRevealDelaySeconds != settings.translationRevealDelaySeconds ||
            draftTranslationMinimumVisibleSeconds != settings.translationMinimumVisibleSeconds ||
            draftLensUpdateIntervalSeconds != settings.lensUpdateIntervalSeconds
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

    private func validateTimingInputs() -> Bool {
        let inputs: [(String, String, ClosedRange<Int>, Bool)] = [
            ("流式原文更新间隔", partialMilliseconds, 0...1000, draftCanShowAnySourceBeforeTranslation),
            ("新一句接管延迟", takeoverMilliseconds, 0...1000, draftCanShowLaterSourceBeforeTranslation),
            ("原文最短可见", sourceMilliseconds, 0...3000,
             draftDisplayLayout == .sentence && draftNeedsTranslationDisplay && draftCanShowAnySourceBeforeTranslation),
            ("译文就绪后延迟", revealMilliseconds, 0...3000, draftNeedsTranslationDisplay),
            ("译文最短停留", translationHoldMilliseconds, 0...5000,
             draftDisplayLayout == .rolling && draftNeedsTranslationDisplay),
            ("最终字幕停留", retentionMilliseconds, 0...30000, draftDisplayRetention == .custom),
            ("眼镜字幕最短发送间隔", lensMilliseconds, 500...2000,
             draftInputSource == .glasses || draftShowOnGlasses)
        ]
        for (name, text, range, isActive) in inputs where isActive {
            guard let value = Int(text), range.contains(value) else {
                saveErrorMessage = "\(name)须填写 \(range.lowerBound)–\(range.upperBound) ms 的整数。"
                showSaveError = true
                return false
            }
        }
        // Commit the text fields synchronously before the save action reads the draft.
        if draftCanShowAnySourceBeforeTranslation, let value = Int(partialMilliseconds) {
            draftPartialUpdateIntervalSeconds = Double(value) / 1000
        }
        if draftCanShowLaterSourceBeforeTranslation, let value = Int(takeoverMilliseconds) {
            draftNextSentenceTakeoverDelaySeconds = Double(value) / 1000
        }
        if draftDisplayLayout == .sentence && draftNeedsTranslationDisplay && draftCanShowAnySourceBeforeTranslation,
           let value = Int(sourceMilliseconds) {
            draftMinimumSourceVisibleSeconds = Double(value) / 1000
        }
        if draftNeedsTranslationDisplay, let value = Int(revealMilliseconds) {
            draftTranslationRevealDelaySeconds = Double(value) / 1000
        }
        if draftDisplayLayout == .rolling && draftNeedsTranslationDisplay,
           let value = Int(translationHoldMilliseconds) {
            draftTranslationMinimumVisibleSeconds = Double(value) / 1000
        }
        if draftDisplayRetention == .custom, let value = Int(retentionMilliseconds) {
            draftCustomRetentionSeconds = Double(value) / 1000
        }
        if draftInputSource == .glasses || draftShowOnGlasses,
           let value = Int(lensMilliseconds) {
            draftLensUpdateIntervalSeconds = Double(value) / 1000
        }
        // Hidden or disabled experiments keep their previous valid values; clear any
        // unfinished text so it cannot block a later save when re-enabled.
        refreshTimingTexts()
        return true
    }

    private func refreshTimingTexts() {
        retentionMilliseconds = String(Int((draftCustomRetentionSeconds * 1000).rounded()))
        partialMilliseconds = String(Int((draftPartialUpdateIntervalSeconds * 1000).rounded()))
        takeoverMilliseconds = String(Int((draftNextSentenceTakeoverDelaySeconds * 1000).rounded()))
        sourceMilliseconds = String(Int((draftMinimumSourceVisibleSeconds * 1000).rounded()))
        revealMilliseconds = String(Int((draftTranslationRevealDelaySeconds * 1000).rounded()))
        translationHoldMilliseconds = String(Int((draftTranslationMinimumVisibleSeconds * 1000).rounded()))
        lensMilliseconds = String(Int((draftLensUpdateIntervalSeconds * 1000).rounded()))
    }

    private func setTimingDefaults() {
        draftCustomRetentionSeconds = 5
        draftPartialUpdateIntervalSeconds = 0
        draftNextSentenceTakeoverDelaySeconds = 0
        draftMinimumSourceVisibleSeconds = 0
        draftTranslationRevealDelaySeconds = 0
        draftTranslationMinimumVisibleSeconds = 1.5
        draftLensUpdateIntervalSeconds = 0.5
        refreshTimingTexts()
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
                                               customRetentionSeconds: draftCustomRetentionSeconds,
                                               partialUpdateIntervalSeconds: draftPartialUpdateIntervalSeconds,
                                               nextSentenceTakeoverDelaySeconds: draftNextSentenceTakeoverDelaySeconds,
                                               minimumSourceVisibleSeconds: draftMinimumSourceVisibleSeconds,
                                               translationRevealDelaySeconds: draftTranslationRevealDelaySeconds,
                                               translationMinimumVisibleSeconds: draftTranslationMinimumVisibleSeconds,
                                               lensUpdateIntervalSeconds: draftLensUpdateIntervalSeconds,
                                               displayLayout: draftDisplayLayout,
                                               rollingConfiguration: draftRollingConfiguration)
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

/// Continuous dragging plus an exact millisecond entry for product experiments.
private struct SubtitleMillisecondControl: View {
    let title: String
    let detail: String
    let range: ClosedRange<Int>
    @Binding var seconds: Double
    @Binding var milliseconds: String
    let identifier: String

    private var parsedMilliseconds: Int? { Int(milliseconds) }
    private var valid: Bool { parsedMilliseconds.map(range.contains) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 8)
                TextField("毫秒", text: $milliseconds)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 76)
                    .accessibilityIdentifier(identifier)
                Text("ms").foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { seconds },
                set: { raw in
                    let millisecondValue = min(range.upperBound, max(range.lowerBound, Int((raw * 1000).rounded())))
                    seconds = Double(millisecondValue) / 1000
                    milliseconds = String(millisecondValue)
                }), in: (Double(range.lowerBound) / 1000)...(Double(range.upperBound) / 1000))
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier + "-slider")
            HStack {
                Text(detail)
                Spacer(minLength: 4)
                Text(String(format: "%.3f s", seconds))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(valid ? Color.secondary : Palette.amber)
            if !valid {
                Text("请输入 \(range.lowerBound)–\(range.upperBound) ms 的整数；无效值不会保存。")
                    .font(.caption2)
                    .foregroundStyle(Palette.amber)
            }
        }
        .onChange(of: milliseconds) { input in
            guard let value = Int(input), range.contains(value) else { return }
            seconds = Double(value) / 1000
        }
    }
}

/// Local sample-only preview. It follows the display rules but never opens an
/// audio input, recognition provider, or TranslationSession.
private struct SubtitleDisplayPreview: View {
    let language: String
    let translationEnabled: Bool
    let mode: SubtitleDisplayMode
    let displayLayout: SubtitleDisplayLayout
    let rollingConfiguration: CaptionRollingConfiguration
    let order: SubtitleBilingualOrder
    let retention: SubtitleDisplayRetention
    let customRetentionSeconds: Double
    let showLiveSourceDuringTranslation: Bool
    let partialUpdateIntervalSeconds: Double
    let nextSentenceTakeoverDelaySeconds: Double
    let minimumSourceVisibleSeconds: Double
    let translationRevealDelaySeconds: Double
    let translationMinimumVisibleSeconds: Double
    let lensUpdateIntervalSeconds: Double

    private enum Scenario: String, CaseIterable {
        case normal, rapidTurns, shortReply, secondTranslationFails

        var name: String {
            switch self {
            case .normal: return "连续对话"
            case .rapidTurns: return "快速插话"
            case .shortReply: return "极短应答"
            case .secondTranslationFails: return "译文失败"
            }
        }
    }

    private struct PreviewState {
        let caption: String
        let status: String
        let explanation: String
        let isPartial: Bool
        let clearedAt: Double?

        init(caption: String, status: String, explanation: String, isPartial: Bool,
             clearedAt: Double? = nil) {
            self.caption = caption
            self.status = status
            self.explanation = explanation
            self.isPartial = isPartial
            self.clearedAt = clearedAt
        }
    }

    @State private var scenario: Scenario = .normal
    @State private var playhead: Double = 8.6
    @State private var scrubMilliseconds = "8600"
    @State private var playing = false
    @State private var lastTick: Date?
    private var retentionSeconds: Double? {
        retention == .custom ? customRetentionSeconds : retention.seconds
    }
    private var duration: Double {
        if displayLayout == .rolling {
            let sourceEnd = rollingSamples.last?.completedAt ?? 0
            let translationEnd = rollingTranslationEvents.last.map { $0.time + translationMinimumVisibleSeconds } ?? 0
            return max(24, max(sourceEnd, translationEnd) + max(3, retentionSeconds ?? 0))
        }
        return max(29, 24 + (retentionSeconds ?? 0))
    }

    var body: some View {
        let state = previewState(at: playhead)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(displayLayout == .rolling ? "五行滚动窗口" : "手机字幕画面", systemImage: "iphone.gen3")
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
                if displayLayout == .rolling {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(state.caption.components(separatedBy: "\n").enumerated()), id: \.offset) { row in
                            Text(row.element.isEmpty ? " " : row.element)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(state.caption)
                    .accessibilityIdentifier("subtitle-preview-caption")
                } else {
                    Text(state.caption.isEmpty ? " " : state.caption)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(state.isPartial ? Color.green : .white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                        .accessibilityIdentifier("subtitle-preview-caption")
                }
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
                Text("精确位置")
                Spacer()
                TextField("毫秒", text: $scrubMilliseconds)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 86)
                    .accessibilityIdentifier("subtitle-preview-position-ms")
                Text("ms")
            }
            .font(.caption)
            HStack {
                Text(timeLabel(playhead))
                Spacer()
                Text(timeLabel(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            LabeledContent("眼镜最短发送间隔", value: "\(Int((lensUpdateIntervalSeconds * 1000).rounded())) ms（不改变手机画面）")
                .font(.caption)
            HStack(spacing: 8) {
                previewJump("首句识别", to: 0.8)
                previewJump("第二句", to: displayLayout == .rolling ? 6.2 : 10)
                previewJump("译文就绪", to: displayLayout == .rolling ? 8.4 : (scenario == .shortReply ? 10.5 : 16.4))
                if scenario == .rapidTurns { previewJump("插话", to: displayLayout == .rolling ? 14.4 : 17.4) }
            }
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
            Text(displayLayout == .rolling
                 ? "此预览使用实时字幕相同的滚动窗口与宽度设置，模拟连续原文、延迟译文和译文最短停留。原文前三行、译文后两行为默认分配，空行也保留位置。示例返回时间固定；译文停留按手机时钟模拟，真机还受眼镜发送与调度影响。不会启动收音或翻译服务。"
                 : "手机画面按上方时序参数模拟连续修订、译文就绪、新句接管和清空；镜片发送间隔不会改变手机预览。示例的识别与翻译返回时间固定，不代表真机耗时；眼镜发送仍受 ACK、链路和系统调度影响。不会启动麦克风、转写或翻译服务。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onReceive(Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()) { tick in
            guard playing else { return }
            let elapsed = max(0, min(0.1, lastTick.map { tick.timeIntervalSince($0) } ?? 0.02))
            lastTick = tick
            playhead = min(duration, playhead + elapsed)
            if playhead >= duration { playing = false; lastTick = nil }
        }
        .onChange(of: duration) { newDuration in
            playhead = min(playhead, newDuration)
            if playhead >= newDuration { playing = false; lastTick = nil }
        }
        .onChange(of: playhead) { value in
            scrubMilliseconds = String(Int((value * 1000).rounded()))
        }
        .onChange(of: scrubMilliseconds) { value in
            guard let milliseconds = Int(value), (0...Int((duration * 1000).rounded())).contains(milliseconds) else { return }
            playhead = Double(milliseconds) / 1000
        }
    }

    private var sourceIsChinese: Bool { language.lowercased().hasPrefix("zh") }
    private var sourceOnlyMode: SubtitleDisplayMode { sourceIsChinese ? .chineseOnly : .englishOnly }
    private var effectiveMode: SubtitleDisplayMode { translationEnabled ? mode : sourceOnlyMode }
    private var sourceOnly: Bool { effectiveMode == sourceOnlyMode }
    private var bilingual: Bool { effectiveMode == .bilingual }
    private func sourceVisibleBeforeTranslation(for sentence: SampleSentence) -> Bool {
        sourceOnly || showLiveSourceDuringTranslation || (bilingual && sentence.number == 1)
    }

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
        if scenario == .shortReply { return sourceIsChinese ? "好。" : "Okay." }
        return sourceIsChinese ? "等一下，左边那辆车正在转弯。" : "Wait, the car on the left is turning."
    }
    private var secondTranslation: String {
        if scenario == .shortReply { return sourceIsChinese ? "Okay." : "好。" }
        return sourceIsChinese ? "Wait, the car on the left is turning." : "等一下，左边那辆车正在转弯。"
    }
    private var thirdSource: String {
        sourceIsChinese ? "好，我已经看到了，我们从后面绕过去。" :
            "Okay, I see it now. Let's go around behind it."
    }
    private var thirdTranslation: String {
        sourceIsChinese ? "Okay, I see it now. Let's go around behind it." :
            "好，我已经看到了，我们从后面绕过去。"
    }

    private struct SampleSentence {
        let source: String
        let translation: String
        let start: Double
        let completedAt: Double
        let translationReady: Double
        let number: Int
    }

    private var emptyPreview: PreviewState {
        PreviewState(caption: "", status: "待播放", explanation: "播放或拖动到毫秒位置，观察连续对话和译文切换。", isPartial: false)
    }

    private var rollingSamples: [SampleSentence] {
        var samples = [
            SampleSentence(source: firstSource, translation: firstTranslation,
                           start: 0.8, completedAt: 6, translationReady: 8.4, number: 1),
            SampleSentence(source: secondSource, translation: secondTranslation,
                           start: 6.2, completedAt: scenario == .shortReply ? 6.45 : 10,
                           translationReady: scenario == .shortReply ? 9 : 11.4, number: 2),
            SampleSentence(source: thirdSource, translation: thirdTranslation,
                           start: 10.2, completedAt: 14.2, translationReady: 16.4, number: 3)
        ]
        if scenario == .rapidTurns {
            samples.append(SampleSentence(
                source: sourceIsChinese ? "先等一等，前面还有一个人。" : "Wait a moment, there is someone ahead.",
                translation: sourceIsChinese ? "Wait a moment, there is someone ahead." : "先等一等，前面还有一个人。",
                start: 14.4, completedAt: 17.4, translationReady: 19.4, number: 4))
        }
        return samples
    }

    private struct RollingTranslationEvent {
        let time: Double
        let text: String
        let sentence: Int
        let final: Bool
    }

    private var rollingTranslationEvents: [RollingTranslationEvent] {
        guard !sourceOnly else { return [] }
        var events: [RollingTranslationEvent] = []
        var nextAllowed = 0.0
        for sample in rollingSamples {
            if scenario == .secondTranslationFails && sample.number == 2 { continue }
            let steps = CaptionRollingBuffer.translationSteps(sample.translation, configuration: rollingConfiguration)
            var revealAt = max(sample.translationReady + translationRevealDelaySeconds, nextAllowed)
            for (index, step) in steps.enumerated() {
                events.append(RollingTranslationEvent(time: revealAt, text: step,
                                                      sentence: sample.number, final: index == steps.count - 1))
                revealAt += translationMinimumVisibleSeconds
            }
            nextAllowed = revealAt
        }
        return events
    }

    private func rollingPreviewState(at time: Double) -> PreviewState {
        var buffer = CaptionRollingBuffer()
        var recognizing = false
        for sample in rollingSamples where time >= sample.start {
            if time >= sample.completedAt {
                buffer.updateSource(sample.source, sentence: sample.number, final: true)
            } else {
                recognizing = true
                let cadence = max(0.05, partialUpdateIntervalSeconds)
                let publishedAt = sample.start + floor((time - sample.start) / cadence) * cadence
                let progress = (publishedAt - sample.start) / (sample.completedAt - sample.start)
                buffer.updateSource(partial(sample.source, progress: progress), sentence: sample.number, final: false)
            }
        }
        let events = rollingTranslationEvents
        for event in events where time >= event.time {
            buffer.updateTranslation(event.text, sentence: event.sentence, final: event.final)
        }
        let lastSourceAt = rollingSamples.last?.completedAt ?? 0
        let completedAt = max(lastSourceAt, events.last.map { $0.time + translationMinimumVisibleSeconds } ?? 0)
        let cleared = retentionSeconds.map { time >= completedAt + $0 } ?? false
        if cleared {
            buffer.reset()
        }
        let snapshot = buffer.snapshot(configuration: rollingConfiguration,
                                       sourceVisible: sourceOnly || bilingual,
                                       translationVisible: !sourceOnly)
        let waiting = !sourceOnly && (events.last?.time ?? 0) > time
        let translationFailed = scenario == .secondTranslationFails && time >= 11.4
        let explanation = translationFailed
            ? "第二段译文失败，译文区保留已有内容；原文区继续滚动，后续成功译文仍会进入窗口。"
            : "原文与译文独立滚动；新原文不会清空译文。译文按\(rollingConfiguration.scrollUnit == .line ? "行" : "词")推进，每步至少停留 \(Int((translationMinimumVisibleSeconds * 1000).rounded())) ms。"
        return PreviewState(caption: snapshot.text,
                            status: time < 0.8 ? "待播放" : (cleared ? "已清空" : (recognizing ? "识别进行中" : (waiting ? "译文排队显示" : "窗口保留"))),
                            explanation: explanation, isPartial: recognizing)
    }

    private func previewState(at time: Double) -> PreviewState {
        if displayLayout == .rolling { return rollingPreviewState(at: time) }
        let first = SampleSentence(source: firstSource, translation: firstTranslation,
                                   start: 0.8, completedAt: 6, translationReady: 8.4, number: 1)
        let second = SampleSentence(source: secondSource, translation: secondTranslation,
                                    start: 10,
                                    completedAt: scenario == .shortReply ? 10.25 : 14,
                                    translationReady: scenario == .shortReply ? 10.5 : 16.4,
                                    number: 2)
        let third = SampleSentence(source: thirdSource, translation: thirdTranslation,
                                   start: 17.4, completedAt: 20.4, translationReady: 22.4, number: 3)
        if time < first.start { return emptyPreview }
        let firstAtSecondStart = sentenceState(first, at: second.start, prior: emptyPreview,
                                               priorVisibleAtStart: false, supersededAt: nil)
        let secondTakeover = estimatedTakeover(of: second,
                                                priorVisibleAtStart: !firstAtSecondStart.caption.isEmpty,
                                                priorExpiryAt: estimatedExpiry(of: first))
        let firstNow = sentenceState(first, at: time, prior: emptyPreview,
                                     priorVisibleAtStart: false, supersededAt: secondTakeover)
        if time < second.start { return firstNow }
        let firstAtThirdStart = sentenceState(first, at: third.start, prior: emptyPreview,
                                              priorVisibleAtStart: false, supersededAt: secondTakeover)
        let secondAtThirdStart = sentenceState(second, at: third.start,
                                              prior: firstAtThirdStart,
                                              priorVisibleAtStart: !firstAtSecondStart.caption.isEmpty,
                                              ownTakeoverAt: secondTakeover,
                                              supersededAt: nil)
        let thirdPriorExpiry = secondAtThirdStart.caption == firstAtThirdStart.caption
            ? estimatedExpiry(of: first) : estimatedExpiry(of: second, ownTakeoverAt: secondTakeover)
        let thirdTakeover = scenario == .rapidTurns
            ? estimatedTakeover(of: third,
                                priorVisibleAtStart: !secondAtThirdStart.caption.isEmpty,
                                priorExpiryAt: thirdPriorExpiry) : nil
        let secondNow = sentenceState(second, at: time, prior: firstNow,
                                      priorVisibleAtStart: !firstAtSecondStart.caption.isEmpty,
                                      ownTakeoverAt: secondTakeover,
                                      supersededAt: thirdTakeover)
        if scenario != .rapidTurns || time < third.start { return secondNow }
        return sentenceState(third, at: time, prior: secondNow,
                             priorVisibleAtStart: !secondAtThirdStart.caption.isEmpty,
                             ownTakeoverAt: thirdTakeover,
                             supersededAt: nil)
    }

    private func estimatedReveal(of sentence: SampleSentence,
                                 ownTakeoverAt: Double? = nil) -> Double {
        let sourceDeadline = sourceVisibleBeforeTranslation(for: sentence)
            ? max(sentence.completedAt, ownTakeoverAt ?? sentence.start) + minimumSourceVisibleSeconds
            : sentence.translationReady
        return max(sourceDeadline, sentence.translationReady + translationRevealDelaySeconds)
    }

    private func estimatedExpiry(of sentence: SampleSentence,
                                 ownTakeoverAt: Double? = nil) -> Double? {
        guard let retentionSeconds else { return nil }
        if sourceOnly { return max(sentence.completedAt, ownTakeoverAt ?? sentence.start) + retentionSeconds }
        return estimatedReveal(of: sentence, ownTakeoverAt: ownTakeoverAt) + retentionSeconds
    }

    private func estimatedTakeover(of sentence: SampleSentence,
                                   priorVisibleAtStart: Bool,
                                   priorExpiryAt: Double?) -> Double {
        if !sourceVisibleBeforeTranslation(for: sentence) {
            return estimatedReveal(of: sentence)
        }
        let requested = sentence.start + (priorVisibleAtStart ? nextSentenceTakeoverDelaySeconds : 0)
        guard priorVisibleAtStart, let priorExpiryAt,
              priorExpiryAt > sentence.start, priorExpiryAt < requested else { return requested }
        // Once the old caption is gone, the pending new partial may take over
        // before the requested hold. The preview shows this transition at expiry.
        return min(requested, priorExpiryAt)
    }

    private func sentenceState(_ sentence: SampleSentence, at time: Double,
                               prior: PreviewState, priorVisibleAtStart: Bool,
                               ownTakeoverAt: Double? = nil,
                               supersededAt: Double?) -> PreviewState {
        if time < sentence.start { return prior }
        let showsSource = sourceVisibleBeforeTranslation(for: sentence)
        let requestedTakeover = sentence.start + (priorVisibleAtStart ? nextSentenceTakeoverDelaySeconds : 0)
        // Runtime reevaluates the held caption on each partial callback. Once the
        // previous final subtitle expires, the next partial can take over early.
        let takeover = ownTakeoverAt ?? min(requestedTakeover,
                                            prior.clearedAt.map { max(sentence.start, $0) } ?? requestedTakeover)
        if time < sentence.completedAt {
            guard showsSource, time >= takeover else {
                return prior
            }
            // Sample recognition updates arrive every 50 ms. A longer user interval
            // merges them; the first eligible update is still immediate.
            let cadence = max(0.05, partialUpdateIntervalSeconds)
            let publishedAt = takeover + floor((time - takeover) / cadence) * cadence
            let progress = max(0, min(1, (publishedAt - sentence.start) / (sentence.completedAt - sentence.start)))
            return PreviewState(caption: partial(sentence.source, progress: progress),
                                status: "临时识别",
                                explanation: "示例每 50 ms 到来一段识别；第\(sentence.number)句最近一次显示于 \(timeLabel(publishedAt))。更新间隔与换句接管延迟已应用。",
                                isPartial: true)
        }
        if showsSource && time < takeover { return prior }
        if sourceOnly {
            return finalized(sentence.source, completedAt: max(sentence.completedAt, takeover), now: time,
                             explanation: "第\(sentence.number)句原文完成，开始最终字幕停留计时。")
        }
        let revealAt = estimatedReveal(of: sentence, ownTakeoverAt: takeover)
        let supersededBeforeReveal = supersededAt.map { time >= $0 && revealAt >= $0 } ?? false
        if scenario == .secondTranslationFails && sentence.number == 2 && time >= revealAt {
            let fallback = bilingual ? sentence.source :
                (effectiveMode == .chineseOnly ? "本句翻译暂不可用" : "Translation unavailable")
            return finalized(fallback, completedAt: revealAt, now: time,
                             explanation: "第二句翻译失败，显示当前语言模式的失败回退。")
        }
        if time < revealAt || supersededBeforeReveal {
            guard showsSource else { return prior }
            return PreviewState(caption: sentence.source, status: "翻译中",
                                explanation: supersededBeforeReveal
                                    ? "新一句已开始；本句迟到的译文不会覆盖后续原文。"
                                    : "完整原文已显示；译文须同时满足原文最短可见和就绪后延迟。",
                                isPartial: false)
        }
        return finalized(composed(source: sentence.source, translation: sentence.translation),
                         completedAt: revealAt, now: time,
                         explanation: "第\(sentence.number)句译文显示；最终字幕停留从此刻计时。")
    }

    private func finalized(_ caption: String, completedAt: Double, now: Double,
                           explanation: String, awaitingTranslation: Bool = false) -> PreviewState {
        if !awaitingTranslation, let seconds = retentionSeconds, now >= completedAt + seconds {
            return PreviewState(caption: "", status: "已清空",
                                explanation: "最终字幕停留 \(Int((seconds * 1000).rounded())) ms 后清空；下一句生成时会重新显示。",
                                isPartial: false, clearedAt: completedAt + seconds)
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
        String(format: "%.3f s", value)
    }

    private func previewJump(_ name: String, to time: Double) -> some View {
        Button(name) {
            playhead = min(duration, time)
            playing = false
            lastTick = nil
        }
        .buttonStyle(.bordered)
        .font(.caption2)
    }
}
