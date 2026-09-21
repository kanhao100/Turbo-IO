import SwiftUI

struct SubtitleDisplayTestView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var voice: CompanionVoiceRuntime
    @EnvironmentObject private var runtime: SubtitleDisplayRuntime
    @State private var confirmedIdle = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("先让字幕出现在眼镜上")
                        .font(.title3.weight(.semibold))
                    Text("本步骤发送测试文字，不收音、不调用转写服务。直接点按钮即可，无需说唤醒词或开启眼镜录音。")
                    Text(runtime.status).foregroundStyle(.secondary)
                        .accessibilityIdentifier("subtitle-display-status")
                }
                Section("1 · 打开显示") {
                    if runtime.phase == .idle {
                        Toggle("眼镜已回首页，没有录音或其他任务", isOn: $confirmedIdle)
                            .accessibilityIdentifier("subtitle-display-idle-confirmation")
                        Button("打开字幕显示") { runtime.open(confirmedIdle: confirmedIdle) }
                            .disabled(!confirmedIdle || !runtime.canOpen)
                            .accessibilityIdentifier("subtitle-display-open")
                        Text(voice.ready ? "打开测试会暂停 App 的 AI 语音待命。" : "请先在“设备”页连接并认证眼镜。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("收到眼镜的设置回应后，发送本轮测试标题。请在镜片上找到相同的校验码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("2 · 核对流式文字") {
                    Text(runtime.expectedText.isEmpty ? "眼镜应显示的文字会出现在这里" : runtime.expectedText)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                        .accessibilityIdentifier("subtitle-display-expected-text")
                    Text("已提交 \(runtime.frames) 帧 · 每秒更新一次")
                        .font(.caption).monospacedDigit().accessibilityIdentifier("subtitle-display-count")
                    Button(runtime.playing ? "正在播放测试文字…" : "播放流式字幕") { runtime.play() }
                        .disabled(!runtime.canPlay).accessibilityIdentifier("subtitle-display-play")
                    Button(runtime.visibleConfirmed ? "已记录：你看到了测试文字" : "我在眼镜上看到了同样的文字") { runtime.confirmVisible() }
                        .disabled(runtime.phase != .ready || runtime.frames == 0 || runtime.visibleConfirmed)
                        .accessibilityIdentifier("subtitle-display-visible")
                    Text("请观察文字是否逐步更新、换行，是否存在重复叠加或闪烁。手机显示“已提交”不代表镜片已经显示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("3 · 停止与退出") {
                    Button("停止并退出字幕", role: .destructive) { runtime.stop() }
                        .disabled(runtime.phase != .opening && runtime.phase != .ready)
                        .accessibilityIdentifier("subtitle-display-stop")
                    if runtime.phase == .stopping || runtime.phase == .uncertain {
                        Text("请查看眼镜是否已回首页；仍停在字幕页时，先在眼镜上退出。")
                            .font(.caption)
                        if runtime.phase == .uncertain {
                            Button("重试退出请求") { runtime.retryExit() }.disabled(!runtime.canRetryExit)
                        }
                        Button("眼镜已退出，结束本轮测试") { runtime.confirmExited(); confirmedIdle = false }
                            .accessibilityIdentifier("subtitle-display-exit-confirmation")
                    }
                    Text("本轮最多 60 秒；离开此页或 App 进入后台时请求退出。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("测试记录") {
                    ShareLink("分享诊断记录", item: runtime.diagnosticText)
                        .accessibilityIdentifier("subtitle-display-share")
                    DisclosureGroup("查看显示会话事件") {
                        ForEach(Array(runtime.events.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("字幕显示测试")
        }
        .onAppear { store.features.prepare() }
        .onDisappear { runtime.stop(reason: "已离开字幕测试页") }
    }
}
