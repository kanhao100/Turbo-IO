import Foundation

#if COMPANION_DEVICE
import Translation

/// Translates finalized subtitle phrases on the device. A runtime session can
/// use only installed languages; the settings view performs the first download
/// through its own SwiftUI `translationTask` session.
@available(iOS 26.0, *)
@MainActor final class AppleCaptionTranslation {
    enum Readiness: String {
        case unsupported, needsDownload, ready

        var message: String {
            switch self {
            case .unsupported: return "Apple 本机翻译不支持这组语言。"
            case .needsDownload: return "需要先下载本机翻译语言包。"
            case .ready: return "本机翻译语言包已就绪。"
            }
        }
    }

    enum TranslationFailure: LocalizedError {
        case unsupported, languagePackMissing, downloadSessionRequired

        var errorDescription: String? {
            switch self {
            case .unsupported: return Readiness.unsupported.message
            case .languagePackMissing: return Readiness.needsDownload.message
            case .downloadSessionRequired: return "请在字幕设置中下载本机翻译语言包。"
            }
        }
    }

    private let session: TranslationSession

    init(source: String, target: String, quality: SubtitleTranslationQuality = .lowLatency) {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        if #available(iOS 26.4, *) {
            session = TranslationSession(installedSource: from, target: to,
                                         preferredStrategy: Self.strategy(for: quality))
        } else {
            session = TranslationSession(installedSource: from, target: to)
        }
    }

    static func readiness(source: String, target: String,
                          quality: SubtitleTranslationQuality = .lowLatency) async -> Readiness {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: strategy(for: quality))
        } else {
            availability = LanguageAvailability()
        }
        switch await availability.status(from: from, to: to) {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Pass this to `.translationTask(configuration)` in a visible settings view.
    /// A directly initialized TranslationSession cannot request new downloads.
    static func configuration(source: String, target: String,
                              quality: SubtitleTranslationQuality = .lowLatency) -> TranslationSession.Configuration {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        if #available(iOS 26.4, *) {
            return TranslationSession.Configuration(source: from, target: to,
                                                    preferredStrategy: strategy(for: quality))
        }
        return TranslationSession.Configuration(source: from, target: to)
    }

    @available(iOS 26.4, *)
    private static func strategy(for quality: SubtitleTranslationQuality) -> TranslationSession.Strategy {
        switch quality {
        case .lowLatency: return .lowLatency
        case .highFidelity: return .highFidelity
        }
    }

    static func prepare(session: TranslationSession) async throws {
        guard session.canRequestDownloads else { throw TranslationFailure.downloadSessionRequired }
        try await session.prepareTranslation()
        guard await session.isReady else { throw TranslationFailure.languagePackMissing }
    }

    func translate(_ text: String) async throws -> String {
        guard await session.isReady else { throw TranslationFailure.languagePackMissing }
        guard !text.isEmpty else { return "" }
        let response = try await session.translate(text)
        return response.targetText
    }

    func cancel() { session.cancel() }
}
#endif
