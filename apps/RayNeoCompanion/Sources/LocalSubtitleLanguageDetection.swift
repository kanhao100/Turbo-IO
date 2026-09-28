import Foundation
import NaturalLanguage

/// Identifies the language of text that has already been supplied by a person
/// or finalized by ASR. It does not identify a language from microphone audio.
/// SpeechTranscriber still needs one locale before audio analysis starts.
enum LocalSubtitleLanguageDetection {
    enum LanguageFamily: String, Sendable {
        case chinese, english

        var name: String {
            switch self {
            case .chinese: return "中文"
            case .english: return "英语"
            }
        }
    }

    struct Result: Sendable {
        let language: LanguageFamily
        let confidence: Double

        /// Language identification cannot distinguish English accents. Keep
        /// the user's existing English locale when the sample is English.
        func suggestedLocale(currentLocale: String) -> String {
            switch language {
            case .chinese: return "zh-CN"
            case .english: return currentLocale == "en-GB" ? "en-GB" : "en-US"
            }
        }
    }

    /// A short phrase is too ambiguous to use as a language-setting suggestion.
    static let minimumLetterCount = 20

    static func detect(sampleText: String) -> Result? {
        let text = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= minimumLetterCount else {
            return nil
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let ranked = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 0.70,
              best.value - (ranked.dropFirst().first?.value ?? 0) >= 0.20 else {
            return nil
        }
        let language: LanguageFamily
        switch best.key {
        case .simplifiedChinese: language = .chinese
        case .english: language = .english
        case .traditionalChinese:
            // The current speech-language picker offers zh-CN only. A written
            // Traditional Chinese sample cannot establish a matching speech
            // locale or dialect, so do not silently recommend zh-CN.
            return nil
        default: return nil
        }
        return Result(language: language, confidence: best.value)
    }

    static func differsFromConfiguredLocale(_ result: Result, configuredLocale: String) -> Bool {
        let configuredChinese = configuredLocale.lowercased().hasPrefix("zh")
        return configuredChinese != (result.language == .chinese)
    }
}
