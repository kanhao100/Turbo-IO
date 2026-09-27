import AVFoundation
import CoreMedia
import Foundation
import RayNeoCaptions

#if COMPANION_DEVICE
import Speech

/// iOS 26 SpeechAnalyzer adapter. Input is little-endian PCM16, mono, 16 kHz.
/// Asset installation is deliberately separate from start: glasses audio must
/// not begin while a model is still downloading.
@available(iOS 26.0, *)
@MainActor final class AppleLocalCaptionASR: CaptionASRProvider {
    enum Readiness: String {
        case unavailable, unsupported, needsDownload, downloading, ready

        var message: String {
            switch self {
            case .unavailable: return "此 iPhone 不支持 Apple 本机语音识别。"
            case .unsupported: return "Apple 本机语音识别不支持所选语言。"
            case .needsDownload: return "需要先下载所选语言的本机识别模型。"
            case .downloading: return "所选语言的本机识别模型正在下载。"
            case .ready: return "本机识别模型已就绪。"
            }
        }
    }

    enum PreparationError: LocalizedError {
        case unavailable, unsupported, downloadIncomplete

        var errorDescription: String? {
            switch self {
            case .unavailable: return Readiness.unavailable.message
            case .unsupported: return Readiness.unsupported.message
            case .downloadIncomplete: return "本机识别模型尚未安装完成，请检查网络后重试。"
            }
        }
    }

    var onText: ((String, Bool) -> Void)?
    var onEndpoint: (() -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    /// State-only events. Never includes audio, transcription, or a device ID.
    var onDiagnostic: ((String) -> Void)?

    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000, channels: 1, interleaved: true)!
    private var generation = UUID()
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var converter: AnalyzerInputConverter?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var pendingPCM: [Data] = []
    private var pendingPCMBytes = 0
    private struct VolatilePhrase {
        let range: CMTimeRange
        let text: String
    }
    private var volatilePhrases: [VolatilePhrase] = []
    private(set) var acceptedPCMBytes = 0
    private(set) var droppedAnalyzerInputs = 0
    var diagnosticSummary: String {
        "appleASRReady=\(inputBuilder != nil) appleASRBytes=\(acceptedPCMBytes) " +
        "appleASRPendingBytes=\(pendingPCMBytes) appleASRDropped=\(droppedAnalyzerInputs)"
    }

    static func readiness(localeIdentifier: String) async -> Readiness {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)) else { return .unsupported }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .downloading: return .downloading
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    static func prepare(localeIdentifier: String) async throws {
        guard SpeechTranscriber.isAvailable else { throw PreparationError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)) else { throw PreparationError.unsupported }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw PreparationError.downloadIncomplete
        }
    }

    func start(options: CaptionOptions, key: String) {
        stop()
        let token = generation
        guard case .fixed(let identifier) = options.languageMode else {
            onDiagnostic?("asr_invalid_locale")
            onFailure?(.configuration)
            return
        }
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await Self.readiness(localeIdentifier: identifier) == .ready,
                      let locale = await SpeechTranscriber.supportedLocale(
                        equivalentTo: Locale(identifier: identifier)) else {
                    guard self.generation == token else { return }
                    self.onDiagnostic?("asr_asset_not_ready")
                    self.onFailure?(.configuration)
                    return
                }
                let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber]) else {
                    guard self.generation == token else { return }
                    self.onDiagnostic?("asr_format_unavailable")
                    self.onFailure?(.configuration)
                    return
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.prepareToAnalyze(in: analyzerFormat)
                guard self.generation == token, !Task.isCancelled else {
                    await analyzer.cancelAndFinishNow()
                    return
                }
                let (inputs, builder) = AsyncStream.makeStream(
                    of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(128))
                // Start before announcing readiness. The analyzer and result stream
                // are independent, so collect results concurrently with audio input.
                let resultsTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard let self, self.generation == token else { break }
                            self.receive(result)
                        }
                    } catch {
                        guard let self, self.generation == token,
                              !Task.isCancelled else { return }
                        self.onDiagnostic?("asr_results_failed")
                        self.onFailure?(.connection)
                    }
                }
                do {
                    try await analyzer.start(inputSequence: inputs)
                } catch {
                    builder.finish()
                    resultsTask.cancel()
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
                guard self.generation == token, !Task.isCancelled else {
                    builder.finish()
                    resultsTask.cancel()
                    await analyzer.cancelAndFinishNow()
                    return
                }
                self.converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
                self.analyzer = analyzer
                self.inputBuilder = builder
                self.resultsTask = resultsTask
                // Glasses may send their first type-4 packet before analyzer setup
                // completes. Preserve a bounded startup window in arrival order.
                let queued = self.pendingPCM
                self.pendingPCM = []
                self.pendingPCMBytes = 0
                for pcm in queued {
                    guard self.generation == token else { return }
                    self.append(pcm)
                }
                guard self.generation == token else { return }
                self.setupTask = nil
                self.onDiagnostic?("asr_ready")
                self.onReady?()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.setupTask = nil
                self.onDiagnostic?("asr_start_failed")
                self.onFailure?(.connection)
            }
        }
    }

    /// A volatile result can become final without being reissued as `isFinal`.
    /// Finalization time advances on later results; commit the last version of
    /// each phrase whose range is now behind that boundary. Replacements and
    /// empty revocations remove the previous version of their overlapping range.
    private func receive(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        volatilePhrases.removeAll { Self.overlaps($0.range, result.range) }
        if !result.isFinal, !text.isEmpty {
            volatilePhrases.append(VolatilePhrase(range: result.range, text: text))
            if volatilePhrases.count > 64 {
                onDiagnostic?("asr_result_backpressure")
                onFailure?(.backpressure)
                return
            }
        }
        let boundary = result.resultsFinalizationTime
        var finals = volatilePhrases.filter {
            CMTimeCompare(Self.end(of: $0.range), boundary) <= 0
        }
        volatilePhrases.removeAll {
            CMTimeCompare(Self.end(of: $0.range), boundary) <= 0
        }
        if result.isFinal, !text.isEmpty {
            finals.append(VolatilePhrase(range: result.range, text: text))
        }
        finals.sort { CMTimeCompare($0.range.start, $1.range.start) < 0 }
        for phrase in finals {
            onText?(phrase.text, true)
            onEndpoint?()
        }
        if !result.isFinal { onText?(text, false) }
    }

    private static func end(of range: CMTimeRange) -> CMTime {
        CMTimeAdd(range.start, range.duration)
    }

    private static func overlaps(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
        CMTimeCompare(lhs.start, end(of: rhs)) < 0 &&
        CMTimeCompare(rhs.start, end(of: lhs)) < 0
    }

    func append(_ pcm: Data) {
        // Glasses packets are usually <= 3,840 bytes; AVAudioEngine taps can
        // legitimately deliver larger converted blocks.
        guard !pcm.isEmpty, pcm.count <= 8_192, pcm.count.isMultiple(of: 2) else {
            onDiagnostic?("asr_invalid_pcm")
            onFailure?(.configuration)
            return
        }
        guard let converter, let inputBuilder else {
            guard setupTask != nil else { return }
            guard pendingPCMBytes + pcm.count <= 160_000 else {
                onDiagnostic?("asr_startup_backpressure")
                onFailure?(.backpressure)
                return
            }
            pendingPCM.append(pcm)
            pendingPCMBytes += pcm.count
            return
        }
        guard
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                            frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let destination = buffer.int16ChannelData?.pointee else {
            onDiagnostic?("asr_invalid_pcm")
            onFailure?(.configuration)
            return
        }
        buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
        pcm.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { _ = memcpy(destination, source, pcm.count) }
        }
        do {
            // nil time means each buffer follows the previous one. The glasses
            // decoder and phone microphone adapter both supply contiguous PCM.
            for input in try converter.convert(buffer, at: nil) {
                switch inputBuilder.yield(input) {
                case .enqueued: break
                case .dropped:
                    droppedAnalyzerInputs += 1
                    onDiagnostic?("asr_input_backpressure")
                    onFailure?(.backpressure)
                    return
                case .terminated: return
                @unknown default: return
                }
            }
            acceptedPCMBytes += pcm.count
        } catch {
            onDiagnostic?("asr_conversion_failed")
            onFailure?(.configuration)
        }
    }

    func stop() {
        generation = UUID()
        setupTask?.cancel(); setupTask = nil
        resultsTask?.cancel(); resultsTask = nil
        inputBuilder?.finish(); inputBuilder = nil
        converter = nil
        pendingPCM = []
        pendingPCMBytes = 0
        volatilePhrases = []
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        acceptedPCMBytes = 0
        droppedAnalyzerInputs = 0
    }
}
#endif
