import SwiftUI
import RayNeoCaptions

/// The only production service editor, used from both voice modes and Tools.
struct VoiceServicesView: View {
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var speech: SpeechSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SpeechConfiguration()
    @State private var asrKey = ""
    @State private var modelKey = ""
    @State private var stored = false
    @State private var saved = false
    private var busy: Bool { voice.enabled || voice.captionOwnsVoice }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("实时字幕和 AI 对话共用下面的转写服务。字幕只需转写 Key；AI 对话还需 DeepSeek Key。保存设置不会开启待命或上传音频。")
                    if busy { Text("请先停止当前字幕或关闭语音待命，再修改服务。").foregroundStyle(.orange) }
                    if !speech.allowsCredentialChanges { Text("本地预览不保存服务密钥，也不连接云端。").foregroundStyle(.secondary) }
                }
                Section("语音转文字 · 两种模式共用") {
                    Picker("转写服务", selection: $draft.service) {
                        ForEach(SpeechService.allCases, id: \.self) { Text($0.name).tag($0) }
                    }.accessibilityIdentifier("speech-service-picker")
                    LabeledContent("模型", value: draft.service.model)
                    if draft.service == .azure {
                        TextField("Azure Region，例如 southeastasia", text: $draft.region)
                            .accessibilityIdentifier("speech-azure-region")
                        Text("填写区域 ID，不带斜杠或网址。").font(.caption)
                    }
                    if draft.service == .aliyun {
                        TextField("阿里云 ASR Host，不含协议和路径", text: $draft.aliyunHost)
                            .keyboardType(.URL).accessibilityIdentifier("speech-aliyun-host")
                        Text("使用自己的 aliyuncs.com 主机；须支持此模型和 DashScope 流式协议。原有 Host 和 Key 会保留。").font(.caption)
                    }
                    Picker("识别语言", selection: $draft.language) {
                        Text("English (UK)").tag("en-GB"); Text("English (US)").tag("en-US"); Text("普通话").tag("zh-CN")
                    }
                    if draft.service == .aliyun || draft.service == .elevenLabs {
                        Text("英式和美式选项都映射为英语识别。").font(.caption)
                    }
                    SecureField("转写 API Key，留空保留", text: $asrKey).accessibilityIdentifier("speech-asr-key")
                    Text(stored ? "当前服务已有密钥" : "当前服务未保存密钥").font(.caption)
                    Button("删除当前转写密钥", role: .destructive) { speech.removeASR(draft); refreshKey() }.disabled(!stored)
                }.disabled(busy || !speech.allowsCredentialChanges)
                Section("生成回答 · 仅 AI 对话需要") {
                    LabeledContent("模型", value: "DeepSeek V4 Flash")
                    SecureField("DeepSeek API Key，留空保留", text: $modelKey).accessibilityIdentifier("speech-model-key")
                    Text(speech.hasModelKey ? "DeepSeek 密钥已保存" : "未配置 DeepSeek 时仍可使用实时字幕").font(.caption)
                    Button("删除 DeepSeek 密钥", role: .destructive) { speech.removeModel() }.disabled(!speech.hasModelKey)
                }.disabled(busy || !speech.allowsCredentialChanges)
                Section {
                    Button("保存服务设置") {
                        saved = speech.save(draft, asrKey: asrKey, modelKey: modelKey)
                        if saved { asrKey = ""; modelKey = ""; draft = speech.configuration; voice.refresh(); refreshKey() }
                    }.disabled(busy || !speech.allowsCredentialChanges).accessibilityIdentifier("speech-save-settings")
                    if saved { Text("已保存。返回后选择会话模式，再手动开启。").foregroundStyle(.green) }
                    if let error = speech.error { Text(error).foregroundStyle(.red) }
                    Text("密钥仅存此 iPhone 钥匙串。各家分开保存；Azure 按 Region、阿里云按 Host 区分。切换服务不会自动向另一家上传音频。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("语音服务设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { draft = speech.configuration; speech.refresh(); refreshKey() }
            .onChange(of: draft.service) { _ in asrKey = ""; saved = false; speech.error = nil; refreshKey() }
            .onChange(of: draft.region) { _ in asrKey = ""; saved = false; refreshKey() }
            .onChange(of: draft.aliyunHost) { _ in asrKey = ""; saved = false; refreshKey() }
        }
    }
    private func refreshKey() { stored = speech.hasKey(for: draft) }
}
