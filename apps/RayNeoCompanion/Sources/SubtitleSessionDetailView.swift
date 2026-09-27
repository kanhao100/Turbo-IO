import SwiftUI
import UIKit
import RayNeoCaptions

struct SubtitleSessionDetailView: View {
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var archive: SubtitleArchiveStore
    @EnvironmentObject private var runtime: SubtitleRealtimeRuntime
    @EnvironmentObject private var playback: SubtitleAudioPlayback
    @State private var record: SubtitleSessionRecord?
    @State private var entries: [CaptionEntry] = []
    @State private var audio: [SubtitleAudioFile] = []
    @State private var message: String?
    @State private var exported: URL?
    @State private var name = ""
    @State private var rename = false
    @State private var deleting = false
    @State private var exporting = false
    @State private var selectedEntryID: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let record {
                    Card {
                        Text(record.title).font(.title2.bold()).textSelection(.enabled)
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Palette.muted)
                        HStack { Badge(text: record.service.name, active: true); Text(record.language); Spacer(); Text("\(record.finalSentences) 句") }.font(.caption)
                        if let model = record.model { Text(model).font(.caption2).foregroundStyle(Palette.muted).textSelection(.enabled) }
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
                            Text("\(audio.count) 个实际保存片段，按顺序回听。点按下方句子可从附近位置播放；字幕时间是接收时间，并非逐字音频对齐。") .font(.caption).foregroundStyle(Palette.muted)
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
                            if canSeek(entry) {
                                Button { seekAndPlay(entry, record: record) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        captionRow(entry)
                                        Image(systemName: selectedEntryID == entry.id && playback.playing ? "waveform" : "play.circle")
                                            .foregroundStyle(Palette.green)
                                            .accessibilityHidden(true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(runtime.active)
                                .accessibilityLabel("从附近位置回听：\(entry.text)")
                                .accessibilityIdentifier("subtitle-history-seek-\(entry.id.uuidString)")
                                .contextMenu { Button("复制字幕") { UIPasteboard.general.string = entry.text } }
                            } else {
                                captionRow(entry).textSelection(.enabled)
                            }
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
        switch kind { case .started: return "开始"; case .stopped: return "结束"; case .gap: return "缺口"; case .unfinished: return "未定稿"; case .final: return "定稿"; case .translation: return "译文" }
    }
    private func captionRow(_ entry: CaptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.date.formatted(date: .omitted, time: .standard))
                if entry.kind != .final { Text(label(entry.kind)) }
            }.font(.caption).foregroundStyle(Palette.muted)
            Text(entry.text).font(entry.kind == .final ? .body : .caption).privacySensitive()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func canSeek(_ entry: CaptionEntry) -> Bool {
        guard !audio.isEmpty else { return false }
        switch entry.kind {
        case .final, .translation, .unfinished: return true
        case .started, .stopped, .gap: return false
        }
    }
    private func seekAndPlay(_ entry: CaptionEntry, record: SubtitleSessionRecord) {
        guard !runtime.active, playback.duration > 0 else { return }
        let storedOffset = entry.audioOffset ?? (entry.kind == .translation
            ? entries.last(where: { $0.kind == .final && $0.date <= entry.date })?.audioOffset
            : nil)
        let position = storedOffset.map { min(playback.duration, max(0, $0)) }
            ?? max(0, estimatedPlaybackPosition(for: entry, record: record) - 3)
        playback.seek(position)
        guard playback.error == nil else { return }
        if !playback.playing { playback.toggle() }
        selectedEntryID = entry.id
    }
    /// Older archives keep receive timestamps only. Infer the recording origin from
    /// the stored PCM duration and subtract explicitly journaled input gaps.
    private func estimatedPlaybackPosition(for entry: CaptionEntry, record: SubtitleSessionRecord) -> TimeInterval {
        let end = record.endedAt ?? entries.last(where: { $0.kind == .stopped })?.date ?? entries.last?.date ?? record.createdAt
        var gapStart: Date?
        var gaps: [(Date, Date)] = []
        for event in entries where event.kind == .gap {
            if event.text.contains("恢复") {
                if let start = gapStart { gaps.append((start, event.date)) }
                gapStart = nil
            } else if gapStart == nil {
                gapStart = event.date
            }
        }
        if let start = gapStart { gaps.append((start, end)) }
        let gapDuration = gaps.reduce(0.0) { $0 + max(0, $1.1.timeIntervalSince($1.0)) }
        let origin = max(record.createdAt, end.addingTimeInterval(-playback.duration - gapDuration))
        // A translated row belongs near speech already recognized, not at the later
        // time when the translation task returned its text.
        let date = entry.kind == .translation
            ? (entries.last(where: { $0.kind == .final && $0.date <= entry.date })?.date ?? entry.date)
            : entry.date
        let elapsedGap = gaps.reduce(0.0) { total, gap in
            total + max(0, min(date, gap.1).timeIntervalSince(max(origin, gap.0)))
        }
        return min(playback.duration, max(0, date.timeIntervalSince(origin) - elapsedGap))
    }
}
