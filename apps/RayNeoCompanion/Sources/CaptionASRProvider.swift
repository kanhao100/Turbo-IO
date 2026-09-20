import Foundation
import RayNeoCaptions

@MainActor protocol CaptionASRProvider: AnyObject {
    var onText: ((String, Bool) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var onFailure: ((CaptionConnectionFailure) -> Void)? { get set }
    func start(options: CaptionOptions, key: String)
    func append(_ pcm: Data)
    func stop()
}

@MainActor enum CaptionASRFactory {
    static func make(_ service: CaptionService) -> CaptionASRProvider? {
        #if COMPANION_DEVICE
        switch service {
        case .azure: return AzureCaptionASR()
        case .deepgram, .elevenLabs: return WebSocketCaptionASR(service: service)
        }
        #else
        return nil // Source-only UI cannot start any cloud transcription provider.
        #endif
    }
}
