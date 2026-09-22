import Foundation
import RayNeoCaptions

@MainActor final class AliyunCaptionASR: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    private enum ActiveDriver { case task, realtime }
    private let taskDriver = AliyunTaskSpeechSession()
    private let realtimeDriver = AliyunSpeechSession()
    private var activeDriver: ActiveDriver?

    func start(options: CaptionOptions, key: String) {
        stop()
        let ready: () -> Void = { [weak self] in self?.onReady?() }
        let text: (String, Bool) -> Void = { [weak self] in self?.onText?($0, $1) }
        let endpoint: () -> Void = { [weak self] in self?.onEndpoint?() }
        let failure: (AliyunSpeechSession.Failure) -> Void = { [weak self] failure in
            let mapped: CaptionConnectionFailure
            switch failure {
            case .configuration: mapped = .configuration
            case .authentication: mapped = .authentication
            case .rejected: mapped = .rejected
            case .connection: mapped = .connection
            case .backpressure: mapped = .backpressure
            }
            self?.onFailure?(mapped)
        }

        switch options.aliyunModel {
        case .qwenAudio31Streaming:
            activeDriver = .task
            taskDriver.onReady = ready
            taskDriver.onText = text
            taskDriver.onEndpoint = endpoint
            taskDriver.onFailure = failure
            taskDriver.start(host: options.aliyunHost, key: key, language: options.cloudLanguage)
        case .qwen3Realtime:
            activeDriver = .realtime
            realtimeDriver.onReady = ready
            realtimeDriver.onText = text
            realtimeDriver.onEndpoint = endpoint
            realtimeDriver.onFailure = failure
            realtimeDriver.start(host: options.aliyunHost, key: key, language: options.cloudLanguage)
        }
    }
    func append(_ pcm: Data) {
        switch activeDriver {
        case .task: taskDriver.append(pcm)
        case .realtime: realtimeDriver.append(pcm)
        case nil: break
        }
    }
    func stop() {
        activeDriver = nil
        taskDriver.stop()
        realtimeDriver.stop()
    }
}
