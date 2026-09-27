import Foundation
import RayNeoCaptions

@MainActor protocol CaptionASRProvider: AnyObject {
    var onText: ((String, Bool) -> Void)? { get set }
    var onEndpoint: (() -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var onFailure: ((CaptionConnectionFailure) -> Void)? { get set }
    var diagnosticSummary: String { get }
    func start(options: CaptionOptions, key: String)
    func append(_ pcm: Data)
    func stop()
}

extension CaptionASRProvider {
    var diagnosticSummary: String { "" }
}

@MainActor enum CaptionASRFactory {
    static func make(_ service: CaptionService) -> CaptionASRProvider? {
        #if COMPANION_DEVICE
        switch service {
        case .azure: return AzureCaptionASR()
        case .aliyun: return AliyunCaptionASR()
        case .deepgram, .elevenLabs: return WebSocketCaptionASR(service: service)
        case .selfHostedQwen: return SelfHostedQwenCaptionASR()
        case .appleLocal:
            if #available(iOS 26.0, *) { return AppleLocalCaptionASR() }
            return nil
        }
        #else
        return nil // Source-only UI cannot start any cloud transcription provider.
        #endif
    }
}
