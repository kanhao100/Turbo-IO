import SwiftUI
import RayNeoCaptions

struct SubtitleSessionDetailView: View {
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var archive: SubtitleArchiveStore
    @EnvironmentObject private var runtime: SubtitleRealtimeRuntime
    @EnvironmentObject private var playback: SubtitleAudioPlayback
    @State private var record: SubtitleSessionRecord?, entries: [CaptionEntry] = [], audio: [SubtitleAudioFile] = []
    @State private var message: String?, exported: URL?, name = "", rename = false, deleting = false, exporting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let record {
                    Card {
                        Text(record.title).font(.title2.bold()).textSelection(.enabled)
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Palette.muted)
                        HStack { Badge(text: record.service.name, active: true); Text(record.language); Spacer(); Text("\(record.finalSentences) 句") }.font(.caption)
                        if record.state != .completed { Label("本次会话中断或未正常收尾；已保存内容可能不完整。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber) }
                        if record.gaps > 0 { Text("记录了 \(record.gaps) 处音频缺口；片段之间不会补静音。") .font(.caption).foregroundStyle(Palette.amber) }
                    }
                    if !audio.isEmpty {
                        Card {
                            Label("回听本次音频", systemImage: "waveform").font(.headline)
                            HStack {
                                Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 42)) }
                                    .disabled(runtime.active).accessibilityLabel(playback.playing ? "暂停回听" : "播放回听")
                                VStack {
                                    Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(0.1, playback.duration)).disabled(runtime.active)
                                    HStack { Text(SubtitleTime.string(playback.position)); Spacer(); Text(SubtitleTime.string(playback.duration)) }.font(.caption.monospacedDigit())
                                }
                            }
                            Text("\(audio.count) 个实际保存片段，按顺序回听。字幕时间是接收时间，并非逐字音频对齐。") .font(.caption).foregroundStyle(Palette.muted)
                            if runtime.active { Text("字幕运行时暂停回听，避免扬声器声音被重复识别。").font(.caption).foregroundStyle(Palette.amber) }
                            if let error = playback.error { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                        }
                    } else { Label(record.savesAudio ? "本次没有可播放的完整音频片段" : "本次选择仅保存文本", systemImage: "doc.text").font(.subheadline).foregroundStyle(Palette.muted) }
                    HStack {
                        Button("导出文字") { export(audio: false) }
                        Spacer()
                        Button("打包文本与音频") { export(audio: true) }
                    }.font(.subheadline).disabled(exporting || runtime.active || runtime.saving)
                    if exporting { ProgressView("正在准备导出…") }
                    if let exported { ShareLink("分享导出文件", item: exported) }
                    Card {
                        Label("完整字幕", systemImage: "text.alignleft").font(.headline)
                        if entries.filter({ $0.kind == .final }).isEmpty { Text("本次未收到定稿字幕。") .foregroundStyle(Palette.muted) }
                        ForEach(entries.suffix(500)) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(entry.date.formatted(date: .omitted, time: .standard)); if entry.kind != .final { Text(label(entry.kind)) } }.font(.caption).foregroundStyle(Palette.muted)
                                Text(entry.text).font(entry.kind == .final ? .body : .caption).textSelection(.enabled).privacySensitive()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if entries.count > 500 { Text("页面显示最近 500 条，导出包含完整内容。") .font(.caption) }
                    }
                    HStack { Button("修改名称") { name = record.title; rename = true }; Spacer(); Button("删除本次会话", role: .destructive) { deleting = true } }
                        .disabled(runtime.active || runtime.saving)
                } else { ProgressView("正在读取会话…") }
                if let message { Text(message).foregroundStyle(Palette.amber) }
            }.padding(20).padding(.bottom, 90)
        }.background(Palette.background.ignoresSafeArea()).navigationTitle("字幕会话").navigationBarTitleDisplayMode(.inline)
            .task { await reload() }.onDisappear { playback.stop() }
            .alert("修改名称", isPresented: $rename) {
                TextField("会话名称", text: $name)
                Button("保存") { Task { await archive.rename(id, title: name); await reload() } }
                Button("取消", role: .cancel) {}
            }
            .alert("删除本次文本和音频？", isPresented: $deleting) {
                Button("永久删除", role: .destructive) { Task { playback.stop(); await archive.delete(id); if archive.error == nil { dismiss() } else { message = archive.error } } }
                Button("取消", role: .cancel) {}
            } message: { Text("此操作无法撤销，请先导出需要保留的内容。不会删除眼镜上的文件。") }
    }
    private func reload() async {
        do { let value = try await archive.detail(id); record = value.record; entries = value.entries; audio = value.audio; playback.configure(audio) }
        catch { message = "无法读取本次会话；原文件保留。" }
    }
    private func export(audio: Bool) {
        exporting = true
        Task { defer { exporting = false }; do { exported = try await archive.export(id, includingAudio: audio) } catch { message = "未能生成导出文件，请结束会话后重试。" } }
    }
    private func label(_ kind: CaptionEntry.Kind) -> String {
        switch kind { case .started: return "开始"; case .stopped: return "结束"; case .gap: return "缺口"; case .unfinished: return "未定稿"; case .final: return "定稿" }
    }
}
