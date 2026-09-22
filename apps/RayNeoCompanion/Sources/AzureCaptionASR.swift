import Foundation
import RayNeoCaptions

#if COMPANION_DEVICE
import MicrosoftCognitiveServicesSpeech

/// All SDK operations are serialized off the UI/audio callback queue. No SDK logs.
/// Callbacks carry a generation so stopped/replaced recognizers cannot update a new session.
@MainActor final class AzureCaptionASR: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onEndpoint: (() -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    private var generation = UUID()
    private let worker = AzureCaptionWorker()
    func start(options: CaptionOptions, key: String) {
        stop()
        let token = generation
        worker.start(options: options, key: key, ready: { [weak self] in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.onReady?() }
        }, text: { [weak self] text, final in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.onText?(text, final); if final, self.generation == token { self.onEndpoint?() } }
        }, failure: { [weak self] in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.onFailure?(.connection) }
        })
    }
    func append(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count <= 3_840, pcm.count % 2 == 0 else { onFailure?(.configuration); return }
        if !worker.append(pcm) { onFailure?(.backpressure) }
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
                let input = SPXPushAudioInputStream() // PCM16, 16 kHz, mono; never phone mic.
                guard let audio = SPXAudioConfiguration(streamInput: input) else { failure(); return }
                let reco: SPXSpeechRecognizer
                if let language = options.cloudLanguage {
                    config.speechRecognitionLanguage = language
                    reco = try SPXSpeechRecognizer(speechConfiguration: config, audioConfiguration: audio)
                } else {
                    guard let detection = SPXAutoDetectSourceLanguageConfiguration(["zh-CN", "en-US", "en-GB"])
                    else { failure(); return }
                    reco = try SPXSpeechRecognizer(speechConfiguration: config,
                        autoDetectSourceLanguageConfiguration: detection, audioConfiguration: audio)
                }
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
