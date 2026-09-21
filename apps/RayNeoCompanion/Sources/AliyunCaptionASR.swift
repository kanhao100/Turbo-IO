import Foundation
import RayNeoCaptions

@MainActor final class AliyunCaptionASR: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onReady: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    private let driver = AliyunSpeechSession()
    func start(options: CaptionOptions, key: String) {
        driver.stop()
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
        driver.start(host: options.aliyunHost, key: key, language: options.language)
    }
    func append(_ pcm: Data) { driver.append(pcm) }
    func stop() { driver.stop() }
}
