import SwiftUI

struct PrompterSettingsView: View {
    @EnvironmentObject private var tuning: PrompterSettingsStore
    @EnvironmentObject private var runtime: SpeechPrompterRuntime
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @Environment(\.dismiss) private var dismiss
    @State private var recognitionSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section("提词方式") {
                    Picker("默认方式", selection: Binding(get: { tuning.tuning.preferredMode }, set: { tuning.update(\.preferredMode, $0) })) {
                        Text("语音跟随").tag("speech")
                        Text("匀速滚动").tag("uniform")
                    }.accessibilityIdentifier("prompter-tuning-mode")
                    Text("匀速滚动直接按设定速度前进，无需配置语音识别。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section("滚动速度") {
                    integer("眼镜匀速速度", keyPath: \.fixedSpeed, range: 60...240, step: 10, suffix: "", id: "prompter-tuning-fixed-speed")
                    number("手机匀速速度", keyPath: \.phoneSpeed, range: 8...80, step: 2, suffix: " 点/秒", id: "prompter-tuning-phone-speed")
                    number("最高语音跟随速度", keyPath: \.scrollUnitsPerSecond, range: 2...40, step: 1, suffix: " 单位/秒", id: "prompter-tuning-scroll-speed")
                }
                Section("旋钮辅助") {
                    number("旋钮滑动倍率", keyPath: \.rotaryStepMultiplier, range: 1...8, step: 0.5, suffix: " 倍", decimals: 1, id: "prompter-tuning-rotary-multiplier")
                    Toggle("匀速模式辅助后继续", isOn: Binding(get: { tuning.tuning.uniformAssistEnabled }, set: { tuning.update(\.uniformAssistEnabled, $0) }))
                        .accessibilityIdentifier("prompter-tuning-uniform-assist")
                }
                Section("调试") {
                    Toggle("显示跟随调试信息", isOn: Binding(get: { tuning.tuning.debugMode }, set: { tuning.update(\.debugMode, $0) }))
                        .accessibilityIdentifier("prompter-tuning-debug-mode")
                    Text("在手机演讲页显示识别原文、稿件匹配位置和音量，并标出正在显示的位置。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    NavigationLink { advancedSettings } label: { Label("高级设置", systemImage: "slider.horizontal.3") }
                        .accessibilityIdentifier("prompter-tuning-advanced")
                    Button("识别服务与语言设置") { recognitionSettings = true }
                        .disabled(runtime.active).accessibilityIdentifier("prompter-recognition-settings")
                }
            }
            .navigationTitle("提词设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("prompter-tuning-done") } }
        }
        .sheet(isPresented: $recognitionSettings) { SubtitleSettingsView() }
        .onChange(of: tuning.tuning) { value in
            runtime.reloadTuning()
            if !value.uniformAssistEnabled, features.teleprompterUniformAssistHolding {
                features.teleprompterHoldUniformScrolling()
            }
        }
    }
    private var advancedSettings: some View {
        Form {
                Section {
                    Text("默认采用宽容匹配、连续小步滚动。识别到的内容只提供前进依据，滚动速度限制每次推进；停顿、插话或证据过期时停住。")
                        .font(.subheadline)
                    Text("设置自动保存。跟随参数立即应用；眼镜排版在下一次传稿时应用。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section("滚动控制") {
                    number("滚动更新间隔", keyPath: \.scrollUpdateIntervalSeconds, range: 0.10...1, step: 0.05, suffix: " 秒", decimals: 2, id: "prompter-tuning-scroll-interval")
                    number("手动辅助后等待", keyPath: \.manualAssistHoldSeconds, range: 0...5, step: 0.1, suffix: " 秒", decimals: 1, id: "prompter-tuning-manual-hold")
                    Text("旋钮或手指滑动后，让自动滚动稍等，语音识别继续运行。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    number("手机滚动回报过滤时间", keyPath: \.rotaryEchoWindowSeconds, range: 0...2, step: 0.1, suffix: " 秒", decimals: 1, id: "prompter-tuning-rotary-echo-window")
                    Text("如果固件回报反复触发旋钮放大，可提高；如果旋钮动作被过滤，可减小或设为 0 关闭近期过滤。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    number("停顿后暂停滚动", keyPath: \.silenceHoldSeconds, range: 0.3...6, step: 0.1, suffix: " 秒", decimals: 1, id: "prompter-tuning-silence-hold")
                    number("匹配有效期", keyPath: \.recognitionEvidenceSeconds, range: 0.5...8, step: 0.1, suffix: " 秒", decimals: 1, id: "prompter-tuning-evidence-hold")
                    number("声音活动阈值", keyPath: \.audioActivityThreshold, range: 0...0.15, step: 0.005, suffix: " RMS", decimals: 3, id: "prompter-tuning-audio-threshold")
                    Text("阈值越低，越容易把小声讲话算作正在说话；环境噪声较大时可适当提高。匹配有效期限制一次识别允许滚动的时长。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section("语音匹配 · 开发者调试") {
                    number("最低相似度", keyPath: \.minimumSimilarity, range: 0.45...0.95, step: 0.01, suffix: "", decimals: 2, id: "prompter-tuning-similarity")
                    Text("默认 0.60，允许漏词、改词和发音偏差。调低更宽容，调高更谨慎。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    integer("最少匹配内容", keyPath: \.minMatchedUnits, range: 4...20, suffix: " 单位", id: "prompter-tuning-min-match")
                    integer("连续确认次数", keyPath: \.requiredStableUpdates, range: 1...4, suffix: " 次", id: "prompter-tuning-stable")
                    integer("向前匹配范围", keyPath: \.maxForwardUnits, range: 12...160, step: 4, suffix: " 单位", id: "prompter-tuning-forward")
                    integer("向后查看范围", keyPath: \.lookBehindUnits, range: 8...80, step: 4, suffix: " 单位", id: "prompter-tuning-lookbehind")
                    integer("向前查看范围", keyPath: \.lookAheadUnits, range: 12...400, step: 8, suffix: " 单位", id: "prompter-tuning-lookahead")
                    Text("一个中文字符或英文字母为一个单位。匹配范围影响识别定位，不允许自动跳过整段；连续滚动仍受最高跟随速度限制。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section("匀速提词") {
                    number("旋钮辅助停留时间", keyPath: \.uniformAssistHoldSeconds, range: 0...5, step: 0.1, suffix: " 秒", decimals: 1, id: "prompter-tuning-uniform-hold")
                    number("暂停与旋钮事件关联窗口", keyPath: \.uniformPauseAssociationSeconds, range: 0...2, step: 0.1, suffix: " 秒", decimals: 1, id: "prompter-tuning-uniform-pause-window")
                    Text("部分固件先报暂停、再报回滚。只有在此窗口内收到回滚才作为旋钮辅助继续；单独暂停不会自动恢复。设为 0 可关闭关联判断。")
                        .font(.caption).foregroundStyle(Palette.muted)
                        .disabled(!tuning.tuning.uniformAssistEnabled)
                    Text("匀速前进时，旋钮可回看或调整位置；停留后从新位置继续前进。主动按“暂停滚动”会保持暂停。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section("眼镜排版") {
                    Picker("眼镜字号", selection: Binding(get: { tuning.tuning.nativeFontSize }, set: { tuning.update(\.nativeFontSize, $0) })) {
                        ForEach([18, 20, 24], id: \.self) { Text("\($0)").tag($0) }
                    }.accessibilityIdentifier("prompter-tuning-native-font")
                    integer("文字区域宽度", keyPath: \.nativeWidth, range: 240...492, step: 12, suffix: "", id: "prompter-tuning-native-width")
                    integer("眼镜行距", keyPath: \.nativeLeading, range: 0...16, suffix: "", id: "prompter-tuning-native-leading")
                    integer("开场倒数", keyPath: \.nativeCountdown, range: 0...10, suffix: " 秒", id: "prompter-tuning-countdown")
                    integer("显示高度档", keyPath: \.nativeHeightGear, range: 1...3, suffix: "", id: "prompter-tuning-height")
                    integer("显示距离档", keyPath: \.nativeDepth, range: 1...3, suffix: "", id: "prompter-tuning-depth")
                    Text("开发校准范围。推荐 18 / 492 / 4 / 倒数 3 秒；其他组合请在眼镜上观察后调整。")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                Section("当前跟随状态") {
                    Text(runtime.status).accessibilityIdentifier("prompter-tuning-status")
                    LabeledContent("显示位置", value: "\(runtime.displayedUTF8Offset) 字节")
                    LabeledContent("已匹配位置", value: "\(runtime.confirmedUTF8Offset) 字节")
                    LabeledContent("输入音量 RMS", value: String(format: "%.3f", runtime.audioRMS))
                    Text(runtime.recognitionText.isEmpty ? "暂无识别文字" : runtime.recognitionText)
                        .font(.caption).textSelection(.enabled)
                    LabeledContent("最近眼镜操作", value: features.teleprompterLastEyeCommand)
                    LabeledContent("眼镜界面", value: features.teleprompterInReader ? "稿件阅读页" : "文稿列表或待进入")
                    LabeledContent("眼镜自动推进", value: features.teleprompterPositionBlocked ? "已保持，等待重新辅助定位" : "可继续")
                    LabeledContent("匀速旋钮辅助", value: features.teleprompterUniformAssistStatus)
                    LabeledContent("旋钮原始位置", value: features.teleprompterRotaryRawOffset.map(String.init) ?? "暂无")
                    LabeledContent("旋钮应用位置", value: features.teleprompterRotaryAppliedOffset.map(String.init) ?? "暂无")
                    Text(features.teleprompterLastPositionKind).font(.caption)
                }
                Section {
                    Button("恢复推荐参数") { tuning.reset() }
                        .accessibilityIdentifier("prompter-tuning-reset")
                }
            }
            .navigationTitle("高级提词设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("prompter-tuning-done") } }
    }
    private func number(_ title: String, keyPath: WritableKeyPath<PrompterTuning, Double>,
                        range: ClosedRange<Double>, step: Double, suffix: String,
                        decimals: Int = 0, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title); Spacer()
                Text(String(format: "%.*f", decimals, tuning.tuning[keyPath: keyPath]) + suffix)
                    .monospacedDigit().foregroundStyle(Palette.muted)
            }
            Slider(value: Binding(get: { tuning.tuning[keyPath: keyPath] }, set: { tuning.update(keyPath, $0) }),
                   in: range, step: step).accessibilityIdentifier(id)
        }
    }
    private func integer(_ title: String, keyPath: WritableKeyPath<PrompterTuning, Int>,
                         range: ClosedRange<Int>, step: Int = 1, suffix: String, id: String) -> some View {
        Stepper(value: Binding(get: { tuning.tuning[keyPath: keyPath] }, set: { tuning.update(keyPath, $0) }),
                in: range, step: step) {
            HStack {
                Text(title); Spacer()
                Text("\(tuning.tuning[keyPath: keyPath])" + suffix).monospacedDigit().foregroundStyle(Palette.muted)
            }
        }.accessibilityIdentifier(id)
    }
}
