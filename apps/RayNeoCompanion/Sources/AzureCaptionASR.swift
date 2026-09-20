import Foundation
import RayNeoCaptions

@MainActor protocol CaptionASRProvider: AnyObject {
    var onText: ((String, Bool) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func start(options: CaptionOptions, key: String)
    func append(_ pcm: Data)
    func stop()
}

#if COMPANION_DEVICE
import MicrosoftCognitiveServicesSpeech

/// All SDK operations are serialized off the UI/audio callback queue. No SDK logs.
/// Callbacks carry a generation so stopped/replaced recognizers cannot update a new session.
@MainActor final class AzureCaptionASR: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?
    private var generation = UUID()
    private let worker = AzureCaptionWorker()
    func start(options: CaptionOptions, key: String) {
        stop()
        let token = generation
        worker.start(options: options, key: key, ready: { [weak self] in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.onReady?() }
        }, text: { [weak self] text, final in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.onText?(text, final) }
        }, failure: { [weak self] in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.onFailure?() }
        })
    }
    func append(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count <= 3_840, pcm.count % 2 == 0 else { onFailure?(); return }
        if !worker.append(pcm) { onFailure?() }
    }
    func stop() { generation = UUID(); worker.stop() }
}

private final class AzureCaptionWorker {
    private let queue = DispatchQueue(label: "companion.azure.speech", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 64)
    // Accessed only on queue; strong references required for a streaming SDK session.
    private var recognizer: SPXSpeechRecognizer?
    private var stream: SPXPushAudioInputStream?
    func start(options: CaptionOptions, key: String, ready: @escaping () -> Void,
               text: @escaping (String, Bool) -> Void, failure: @escaping () -> Void) {
        queue.async { [self] in
            do {
                let config = try SPXSpeechConfiguration(subscription: key, region: options.region)
                config.speechRecognitionLanguage = options.language
                let input = SPXPushAudioInputStream() // PCM16, 16 kHz, mono; never phone mic.
                guard let audio = SPXAudioConfiguration(streamInput: input) else { failure(); return }
                let reco = try SPXSpeechRecognizer(speechConfiguration: config, audioConfiguration: audio)
                reco.addRecognizingEventHandler { _, event in
                    if let value = event.result.text, !value.isEmpty { text(value, false) }
                }
                reco.addRecognizedEventHandler { _, event in
                    // An empty/NoMatch final retracts any provisional subtitle.
                    text(event.result.text ?? "", true)
                }
                reco.addSessionStartedEventHandler { _, _ in ready() }
                reco.addCanceledEventHandler { _, _ in failure() }
                reco.addSessionStoppedEventHandler { _, _ in failure() }
                stream = input; recognizer = reco
                try reco.startContinuousRecognition()
            } catch { failure() } // Never surface a raw service error or subscription key.
        }
    }
    func append(_ pcm: Data) -> Bool {
        guard slots.wait(timeout: .now()) == .success else { return false }
        queue.async { [self] in defer { slots.signal() }; stream?.write(pcm) }
        return true
    }
    func stop() {
        queue.async { [self] in
            stream?.close(); try? recognizer?.stopContinuousRecognition()
            recognizer = nil; stream = nil
        }
    }
}
#endif
