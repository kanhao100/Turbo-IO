import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var captions: CaptionRuntime
    @EnvironmentObject private var speech: SpeechSettingsStore
    @EnvironmentObject private var timeline: ConversationTimeline
    @State private var mode = "captions"
    @State private var showServices = false
    @State private var showSimulation = false
    @State private var showDiagnostics = false
    @State private var confirmStart = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("会话模式", selection: $mode) {
                Text("实时字幕").tag("captions")
                Text("AI 语音对话").tag("conversation")
            }.pickerStyle(.segmented).padding()
                .disabled(runtime.enabled || captions.active).accessibilityIdentifier("voice-mode-picker")
            if mode == "captions" { NavigationStack { RealtimeCaptionView(embedded: true) } }
            else { conversation }
        }
        .navigationTitle("语音")
        .onAppear {
            runtime.prepare(); speech.refresh()
            if captions.active { mode = "captions" } else if runtime.enabled { mode = "conversation" }
        }
        .sheet(isPresented: $showServices) { VoiceServicesView() }
        .sheet(isPresented: $showSimulation) { SessionSimulationView() }
        #if COMPANION_DEVICE
        .sheet(isPresented: $showDiagnostics, onDismiss: { runtime.refresh() }) {
            NavigationStack {
                VoiceDiagnosticsView(runtime: runtime)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDiagnostics = false } } }
            }
        }
        #endif
        .confirmationDialog("唤醒后音频发送给 \(speech.configuration.service.name)，定稿文字发送给 DeepSeek 生成回答；服务可能计费。", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("开启 AI 对话待命") { runtime.start(cloud: true, continuous: true) }
            Button("取消", role: .cancel) {}
        }
    }
    private var conversation: some View {
        Screen(title: "AI 语音对话", eyebrow: "识别 → 生成回答 → 镜片显示") {
            HStack {
                Label(runtime.phaseLabel, systemImage: runtime.enabled ? "waveform" : "moon")
                Spacer(); Badge(text: runtime.supportsDevice ? (runtime.ready ? "已认证" : "未连接") : "本地预览")
            }.font(.headline)
            Card {
                LabeledContent("转写", value: speech.configuration.service.name)
                LabeledContent("回答", value: "DeepSeek V4 Flash")
                Button("语音服务设置") { showServices = true }.accessibilityIdentifier("model-settings")
                ForEach(speech.conversationRequirements, id: \.self) { Text("待配置：" + $0).font(.caption).foregroundStyle(Palette.amber) }
                if !runtime.ready { Text("请先连接并认证眼镜。").font(.caption).foregroundStyle(Palette.muted) }
            }
            VStack(alignment: .leading, spacing: 18) {
                Label("你说的话", systemImage: "mic").font(.caption)
                Text(runtime.transcript.isEmpty ? "主动唤醒眼镜后开始识别" : runtime.transcript)
                    .font(.system(size: 18)).privacySensitive()
                Divider()
                Label("DeepSeek 回答", systemImage: "sparkles").font(.caption)
                Text(runtime.answer.isEmpty ? "整句话定稿后生成回答；继续说话可打断" : runtime.answer)
                    .font(.system(size: 16)).lineSpacing(6).privacySensitive()
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("live-voice-content")
            if let error = runtime.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber)
            }
            if runtime.enabled {
                PrimaryButton(title: "关闭 AI 对话待命", icon: "stop.circle") { runtime.stop() }
                Button("结束本轮，保留待命") { runtime.endRound() }
            } else if !speech.conversationRequirements.isEmpty {
                PrimaryButton(title: "补全对话配置", icon: "gearshape") { showServices = true }
            } else {
                PrimaryButton(title: "开启 AI 对话待命", icon: "waveform",
                    enabled: runtime.supportsDevice && runtime.ready && !captions.active) { confirmStart = true }
            }
            Text(runtime.enabled ? "等待真实唤醒；开启待命不等于正在录音。切换模式前请先关闭待命。" : "尚未开启。保存服务配置不会自动启动对话。")
                .font(.caption).foregroundStyle(Palette.muted)
            Text("连续对话保留 120 秒保护上限；回答发送完成后 10 秒无有效新句退出本轮。当前仅显示文字回答，无语音播放。")
                .font(.caption).foregroundStyle(Palette.muted)
            NavigationLink("对话时间轴、导出与分享") { ConversationTimelineView() }
            if let error = timeline.storageError { Text(error).foregroundStyle(Palette.amber) }
            NavigationLink("Codex 任务与审批") { CodexCompanionView() }
            NavigationLink("AI Tools · 模型可用工具") { ModelToolsView() }
            DisclosureGroup("诊断与演示") {
                Button("本地流程演示") { showSimulation = true }
                if runtime.supportsDevice { Button("连接与诊断") { showDiagnostics = true } }
                Text(runtime.latestEvent).font(.system(size: 10, design: .monospaced))
                Button("清除本次屏幕文字") { runtime.clearText() }
            }
        }
    }
}
