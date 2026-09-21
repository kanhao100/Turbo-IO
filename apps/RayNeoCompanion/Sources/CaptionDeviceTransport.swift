import Foundation

/// The hardware boundary used by the real caption runtime and synthetic tests.
/// Wakeup initialization uses Launcher; caption/audio commands use voiceAssistant.
@MainActor protocol CaptionDeviceTransport: AnyObject {
    var speech: SpeechSettingsStore { get }
    var supportsDevice: Bool { get }
    var deviceID: String? { get }
    var enabled: Bool { get }
    var featureIsBusy: (() -> Bool)? { get }
    var onCaptionEnvelope: ((String, UInt32, Data?, TimeInterval) -> Void)? { get set }
    var onCaptionInputLoss: ((String) -> Void)? { get set }
    func prepare()
    func ownVoiceForCaptions(_ owns: Bool)
    func sendCaptionWakeup(target: String) throws
    func sendCaption(target: String, payload: Data) throws
}

struct CaptionDecodedAudio {
    let pcm: Data
    let frames: Int
    let voicedMask: UInt32
}

protocol CaptionAudioDecoder: AnyObject {
    func decode(_ audio: Data) -> CaptionDecodedAudio?
    func reset()
}

#if COMPANION_DEVICE
/// Owns the same bounded Opus/WebRTC decoder previously held by CaptionRuntime.
final class NativeCaptionAudioDecoder: CaptionAudioDecoder {
    private let handle: OpaquePointer
    init?() {
        guard let handle = RNVoiceVADCreate() else { return nil }
        self.handle = handle
    }
    deinit { RNVoiceVADDestroy(handle) }
    func reset() { _ = RNVoiceVADReset(handle) }
    func decode(_ audio: Data) -> CaptionDecodedAudio? {
        var samples = [Int16](repeating: 0, count: 1_920), mask: UInt32 = 0
        let frames = audio.withUnsafeBytes { bytes in
            samples.withUnsafeMutableBufferPointer { buffer in
                RNVoiceVADProcessPCM(handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                                    bytes.count, &mask, buffer.baseAddress, buffer.count)
            }
        }
        guard frames > 0, frames <= 12 else { return nil }
        let pcm = samples.withUnsafeBytes { Data($0.prefix(Int(frames) * 160 * 2)) }
        return CaptionDecodedAudio(pcm: pcm, frames: Int(frames), voicedMask: mask)
    }
}
#endif
