import Foundation
import RayNeoCaptions

/// Optional user-operated Qwen3-ASR endpoint. It shares the verified
/// OpenAI-Realtime wire implementation, but keeps credentials in a separate
/// Keychain namespace from both Alibaba Cloud regions.
@MainActor final class SelfHostedQwenCaptionASR: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    private let driver = AliyunSpeechSession()

    func start(options: CaptionOptions, key: String) {
        stop()
        guard options.service == .selfHostedQwen else {
            onFailure?(.configuration)
            return
        }
        driver.onReady = { [weak self] in self?.onReady?() }
        driver.onText = { [weak self] in self?.onText?($0, $1) }
        driver.onEndpoint = { [weak self] in self?.onEndpoint?() }
        driver.onFailure = { [weak self] failure in
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
        driver.start(endpoint: options.selfHostedEndpoint, key: key, language: options.cloudLanguage)
    }

    func append(_ pcm: Data) { driver.append(pcm) }
    func stop() { driver.stop() }
}
