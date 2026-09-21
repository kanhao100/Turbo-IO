import Foundation

/// Main-queue boundary between session orchestration and a selected recognizer.
/// A final segment and an utterance endpoint are separate events (notably Deepgram).
struct VoiceRecognitionPort {
    let start: (@escaping (String, Bool) -> Void, @escaping () -> Void, @escaping (String) -> Void) -> Void
    let append: (Data) -> Void
    let stop: () -> Void
}
