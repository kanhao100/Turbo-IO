import AVFoundation
import CoreMedia
import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if COMPANION_DEVICE
import Speech
#endif

private enum LocalAudioExperimentError: LocalizedError {
    case invalidFile, fileTooLarge, fileTooLong, transcriptTooLarge, emptyFile
    case unavailable, modelNotReady, noTranscript

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "无法读取或解码这份录音。请使用 iOS 支持的 WAV、M4A、MP3、CAF 等音频文件。"
        case .fileTooLarge: return "文件超过 100 MiB，实验入口暂不处理。"
        case .fileTooLong: return "录音超过 30 分钟，实验入口暂不处理。"
        case .transcriptTooLarge: return "识别文字超过实验入口的容量限制。"
        case .emptyFile: return "录音为空，或没有可分析的音频采样。"
        case .unavailable: return "此构建或设备不支持 iOS 26 Apple 本机语音识别。"
        case .modelNotReady: return "所选语言的本机识别模型不可用或尚未就绪。请检查语言和网络后重试。"
        case .noTranscript: return "分析已完成，但没有识别出文字。请检查语言选择和录音内容。"
        }
    }
}

private struct LocalAudioExperimentInput: Sendable {
    let url: URL
    let directory: URL
    let duration: TimeInterval
    let byteCount: Int
}

/// File coordination can wait on a provider. An explicit signal cancels that
/// wait and is also checked by the copy loop inside the coordinated accessor.
private final class LocalAudioExperimentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?

    func check() throws {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    func register(_ coordinator: NSFileCoordinator) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            coordinator.cancel()
            throw CancellationError()
        }
        self.coordinator = coordinator
        lock.unlock()
    }

    func unregister() {
        lock.lock()
        coordinator = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let coordinator = self.coordinator
        lock.unlock()
        coordinator?.cancel()
    }
}

/// A File Provider URL is only touched while its security scope and file
/// coordination are active. The analyzer receives a bounded private copy.
private enum LocalAudioExperimentStaging {
    static let maximumBytes = 100 * 1_024 * 1_024
    static let maximumSeconds: TimeInterval = 30 * 60

    static func stage(_ source: URL, cancellation: LocalAudioExperimentCancellation) throws
        -> LocalAudioExperimentInput {
        try cancellation.check()
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("LocalAudioTranscriptionExperimentV1", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var completed = false
        defer { if !completed { try? manager.removeItem(at: directory) } }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700,
                                                 .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator()
        try cancellation.register(coordinator)
        defer { cancellation.unregister() }
        var coordinationError: NSError?
        var copyResult: Result<(URL, Int), Error>?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges,
                               error: &coordinationError) { readableURL in
            copyResult = Result {
                try cancellation.check()
                let properties = try readableURL.resourceValues(forKeys:
                    [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                    throw LocalAudioExperimentError.invalidFile
                }
                guard let size = properties.fileSize, size > 0 else {
                    throw LocalAudioExperimentError.emptyFile
                }
                guard size <= maximumBytes else { throw LocalAudioExperimentError.fileTooLarge }
                let nameExtension = readableURL.pathExtension.lowercased()
                let safeExtension = nameExtension.range(of: #"^[a-z0-9]{1,8}$"#,
                                                        options: .regularExpression) != nil
                    ? nameExtension : "audio"
                let destination = directory.appendingPathComponent("imported." + safeExtension)
                guard manager.createFile(atPath: destination.path, contents: nil,
                    attributes: [.posixPermissions: 0o600,
                                 .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                    throw LocalAudioExperimentError.invalidFile
                }
                let input = try FileHandle(forReadingFrom: readableURL)
                let output = try FileHandle(forWritingTo: destination)
                defer { try? input.close(); try? output.close() }
                var copied = 0
                while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                    try cancellation.check()
                    copied += chunk.count
                    guard copied <= maximumBytes else { throw LocalAudioExperimentError.fileTooLarge }
                    try output.write(contentsOf: chunk)
                }
                guard copied > 0 else { throw LocalAudioExperimentError.emptyFile }
                return (destination, copied)
            }
        }
        try cancellation.check()
        if let coordinationError { throw coordinationError }
        guard let copyResult else { throw LocalAudioExperimentError.invalidFile }
        let (url, byteCount) = try copyResult.get()
        try cancellation.check()
        let audioFile: AVAudioFile
        do { audioFile = try AVAudioFile(forReading: url) }
        catch { throw LocalAudioExperimentError.invalidFile }
        let format = audioFile.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, format.channelCount <= 32 else {
            throw LocalAudioExperimentError.invalidFile
        }
        guard audioFile.length > 0 else { throw LocalAudioExperimentError.emptyFile }
        let duration = Double(audioFile.length) / format.sampleRate
        guard duration.isFinite, duration <= maximumSeconds else {
            throw LocalAudioExperimentError.fileTooLong
        }
        try cancellation.check()
        completed = true
        return LocalAudioExperimentInput(url: url, directory: directory,
                                         duration: duration, byteCount: byteCount)
    }
}

@MainActor private final class LocalAudioTranscriptionExperiment: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = "请选择一份本机录音开始实验。"
    @Published private(set) var transcript = ""
    @Published private(set) var recognizedSeconds: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var fileName = ""
    @Published private(set) var error: String?
    private var work: Task<Void, Never>?
    #if COMPANION_DEVICE
    private var analyzer: SpeechAnalyzer?
    #endif

    func start(url: URL, language: String) {
        guard !busy else { return }
        busy = true
        error = nil
        transcript = ""
        recognizedSeconds = 0
        duration = 0
        fileName = url.lastPathComponent
        status = "正在从文件提供器复制录音…"
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.work = nil }
            let cancellation = LocalAudioExperimentCancellation()
            let copy = Task.detached(priority: .userInitiated) {
                try LocalAudioExperimentStaging.stage(url, cancellation: cancellation)
            }
            do {
                let input = try await withTaskCancellationHandler {
                    try await copy.value
                } onCancel: {
                    cancellation.cancel()
                    copy.cancel()
                }
                defer { try? FileManager.default.removeItem(at: input.directory) }
                try Task.checkCancellation()
                self.duration = input.duration
                #if COMPANION_DEVICE
                try await self.transcribe(input, language: language)
                #else
                throw LocalAudioExperimentError.unavailable
                #endif
            } catch is CancellationError {
                self.status = "已取消；导入的临时副本已清理。"
                self.error = nil
            } catch {
                if Task.isCancelled {
                    self.status = "已取消；导入的临时副本已清理。"
                    self.error = nil
                } else {
                    self.status = "实验未完成。"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard busy else { return }
        status = "正在取消并清理临时文件…"
        work?.cancel()
        #if COMPANION_DEVICE
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        #endif
    }

    func reportImporterError(_ failure: Error) {
        error = "文件选择失败：\(failure.localizedDescription)"
    }

    #if COMPANION_DEVICE
    @available(iOS 26.0, *)
    private func transcribe(_ input: LocalAudioExperimentInput, language: String) async throws {
        guard SpeechTranscriber.isAvailable else { throw LocalAudioExperimentError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language)) else {
            throw LocalAudioExperimentError.modelNotReady
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        guard assetStatus != .unsupported else { throw LocalAudioExperimentError.modelNotReady }
        if assetStatus != .installed {
            try Task.checkCancellation()
            status = "正在准备所选语言的本机识别模型；可能需要下载…"
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            try Task.checkCancellation()
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw LocalAudioExperimentError.modelNotReady
            }
        }
        try Task.checkCancellation()
        let audioFile: AVAudioFile
        do { audioFile = try AVAudioFile(forReading: input.url) }
        catch { throw LocalAudioExperimentError.invalidFile }
        // The documented transcription preset publishes final results without
        // live volatile replacements. SpeechTranscriber runs on the device.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        defer { self.analyzer = nil }
        status = "Apple 本机识别中；\(Int(input.duration)) 秒录音，\(input.byteCount / 1_024) KiB。"
        let results = Task { @MainActor [weak self] in
            var phrases: [String] = []
            var byteCount = 0
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let phrase = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { continue }
                byteCount += phrase.utf8.count
                guard phrases.count < 10_000, byteCount <= 1_024 * 1_024 else {
                    throw LocalAudioExperimentError.transcriptTooLarge
                }
                phrases.append(phrase)
                let end = CMTimeGetSeconds(CMTimeAdd(result.range.start, result.range.duration))
                if end.isFinite, end > 0 {
                    self?.recognizedSeconds = min(input.duration, max(self?.recognizedSeconds ?? 0, end))
                }
                self?.transcript = phrases.joined(separator: "\n")
            }
            return phrases.joined(separator: "\n")
        }
        do {
            let lastSample = try await withTaskCancellationHandler {
                try await analyzer.analyzeSequence(from: audioFile)
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            guard let lastSample else {
                await analyzer.cancelAndFinishNow()
                throw LocalAudioExperimentError.emptyFile
            }
            status = "录音已读完，正在等待末尾文字定稿…"
            // analyzeSequence only means that the file was read. Finishing at
            // its final sample waits for analysis and closes the result stream.
            try await analyzer.finalizeAndFinish(through: lastSample)
            try Task.checkCancellation()
            let text = (try await results.value).trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !text.isEmpty else { throw LocalAudioExperimentError.noTranscript }
            transcript = text
            recognizedSeconds = input.duration
            status = "本机转录完成。原文件未修改。"
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await results.value
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    #endif
}

struct LocalAudioTranscriptionExperimentView: View {
    @EnvironmentObject private var settings: SubtitleSettingsStore
    @StateObject private var experiment = LocalAudioTranscriptionExperiment()
    @State private var showImporter = false
    @State private var language = "zh-CN"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Label("导入录音 · 本机识别实验", systemImage: "waveform.badge.magnifyingglass")
                        .font(.headline)
                    Text("选择一份音频文件，在 iPhone 上用 iOS 26 SpeechAnalyzer 转成文字。不会启动麦克风、眼镜收音或云端转写，也不会修改原文件。")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                    Text("支持系统可解码的音频；单文件不超过 100 MiB、30 分钟。所选语言的本机模型若未就绪，系统会先尝试下载并安装。")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Picker("录音语言", selection: $language) {
                        Text("中文").tag("zh-CN")
                        Text("英语（美国）").tag("en-US")
                        Text("英语（英国）").tag("en-GB")
                    }
                    .disabled(experiment.busy)
                    .accessibilityIdentifier("local-file-asr-language")
                    Button("选择录音文件") { showImporter = true }
                        .disabled(experiment.busy)
                        .accessibilityIdentifier("local-file-asr-import")
                }
                Card {
                    Text(experiment.status).font(.subheadline)
                    if !experiment.fileName.isEmpty {
                        Text(experiment.fileName).font(.caption).foregroundStyle(Palette.muted)
                            .lineLimit(2).privacySensitive()
                    }
                    if experiment.busy {
                        if experiment.duration > 0 && experiment.recognizedSeconds > 0 {
                            ProgressView(value: experiment.recognizedSeconds, total: experiment.duration)
                            Text("已定稿约 \(SubtitleTime.string(experiment.recognizedSeconds)) / \(SubtitleTime.string(experiment.duration)) 的音频")
                                .font(.caption).foregroundStyle(Palette.muted)
                        } else { ProgressView("处理中…") }
                        Button("取消实验") { experiment.cancel() }
                            .accessibilityIdentifier("local-file-asr-cancel")
                    }
                    if let error = experiment.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Palette.amber)
                            .accessibilityIdentifier("local-file-asr-error")
                    }
                }
                if !experiment.transcript.isEmpty {
                    Card {
                        Label("转录文字", systemImage: "text.alignleft").font(.headline)
                        Text(experiment.transcript).textSelection(.enabled).privacySensitive()
                            .accessibilityIdentifier("local-file-asr-transcript")
                        if !experiment.busy && experiment.error == nil {
                            ShareLink("分享转录文字", item: experiment.transcript)
                        }
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 80)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("导入录音实验")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if ["zh-CN", "en-US", "en-GB"].contains(settings.options.language) {
                language = settings.options.language
            }
        }
        .onDisappear { experiment.cancel() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): experiment.start(url: url, language: language)
            case .failure(let error):
                // File selection errors are shown inline; cancellation is quiet.
                if (error as NSError).code != NSUserCancelledError {
                    experiment.reportImporterError(error)
                }
            }
        }
    }
}
