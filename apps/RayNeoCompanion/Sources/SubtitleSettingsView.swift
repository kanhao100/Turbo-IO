import SwiftUI
import RayNeoCaptions

struct SubtitleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var settings: SubtitleSettingsStore
    @EnvironmentObject private var runtime: SubtitleRealtimeRuntime
    @EnvironmentObject private var features: CompanionDeviceFeatures
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @State private var draft = CaptionOptions()
    @State private var key = ""
    @State private var saved = false
    private var busy: Bool { runtime.active || runtime.saving || voice.enabled || voice.subtitleOwnsDisplay }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("字幕只需要转写服务", systemImage: "captions.bubble").font(.headline)
                    Text("选用一家服务即可。密钥留在本机钥匙串，音频只发送给当前所选服务；不需要 DeepSeek，也不生成 AI 回答。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("转写服务") {
                    Picker("服务", selection: $draft.service) { ForEach(CaptionService.allCases, id: \.self) { Text($0.name).tag($0) } }
                        .accessibilityIdentifier("subtitle-provider")
                    LabeledContent("模型", value: draft.service.model)
                    if draft.service == .azure { TextField("Azure Region，例如 eastus", text: $draft.region).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    if draft.service == .aliyun { TextField("阿里云 Host（aliyuncs.com）", text: $draft.aliyunHost).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    Picker("识别语言", selection: $draft.language) {
                        Text("中文").tag("zh-CN"); Text("English · UK").tag("en-GB"); Text("English · US").tag("en-US")
                    }
                    SecureField(settings.hasKey(for: draft) ? "已保存密钥，留空保留" : "填写自己的 API Key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("subtitle-api-key")
                }.disabled(busy)
                Section("本机保存") {
                    Toggle("同时保存音频", isOn: $draft.recordAudio).accessibilityIdentifier("subtitle-save-audio")
                    Text("文本总会保存。音频为处理后的 16 kHz 单声道 WAV，每 60 秒分段；已知断流另起一段，不补静音。约 115 MB/小时，仅存此 App，不自动上传网盘。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("单次时长上限", selection: $draft.maximumSeconds) {
                        Text("30 分钟").tag(1800); Text("60 分钟").tag(3600); Text("120 分钟").tag(7200)
                    }
                    Button("保存字幕设置") { draft.idleSeconds = 0; saved = settings.save(draft, key: key); if saved { key = "" } }
                        .accessibilityIdentifier("subtitle-save-settings")
                    if saved { Text("已保存；不会自动开始收音。之后从手机或眼镜启动时不再二次确认。") .font(.caption).foregroundStyle(Palette.green) }
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
                }
                if !voice.supportsDevice { Text("本地预览不保存密钥、不连接眼镜或转写服务。").font(.caption) }
                if voice.enabled { Button("先关闭 AI 对话待命") { voice.stop() } }
            }
            .navigationTitle("字幕设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { draft = settings.options; settings.refresh() }
            .onChange(of: draft.service) { _ in key = ""; saved = false }
        }
    }
}
