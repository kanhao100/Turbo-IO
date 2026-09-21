import XCTest
import Combine
import RayNeoCaptions
import RayNeoProtocol
@testable import RayNeoCompanion

final class CaptionRuntimeTests: XCTestCase {
    @MainActor func testEachServiceInitializesWakeupBeforeRealWakeAudioAndCaptions() async throws {
        for service in SpeechService.allCases {
            let f = try fixture(service)
            XCTAssertTrue(f.voice.events.isEmpty)
            XCTAssertNil(f.credentials.model)
            XCTAssertEqual(f.credentials.asr.count, 1)
            await f.runtime.arm(f.runtime.options)?.value
            XCTAssertEqual(f.runtime.phase, .armed)
            XCTAssertEqual(f.voice.events, [.wakeup("test-glasses")])
            XCTAssertEqual(f.provider.starts, 0)
            XCTAssertEqual(f.runtime.elapsed, 0)
            XCTAssertNil(f.runtime.arm(f.runtime.options)) // Repeated taps cannot reinitialize.

            f.emit(11) // Next-turn requests and audio are not a real initial wake.
            f.emit(3, audio: Data([1, 2]))
            f.provider.onText?("unsolicited result", true)
            XCTAssertEqual(f.provider.starts, 0)
            XCTAssertTrue(f.decoder.packets.isEmpty)
            XCTAssertTrue(f.runtime.recent.isEmpty)

            f.emit(1)
            XCTAssertEqual(f.runtime.phase, .listening)
            XCTAssertEqual(f.voice.events, [.wakeup("test-glasses"),
                .assistant(AssistantRecorderPrototype.control(start: true))])
            XCTAssertEqual(f.provider.started?.service, service)
            XCTAssertEqual(f.provider.starts, 1)
            f.emit(1)
            XCTAssertEqual(f.provider.starts, 1)
            XCTAssertEqual(f.voice.events.count, 2)

            f.time.value += 0.01
            f.emit(3, audio: Data([1, 2]))
            XCTAssertEqual(f.decoder.packets, [Data([1, 2])])
            XCTAssertEqual(f.provider.audio, [f.decoder.pcm])
            f.provider.onText?("synthetic caption", true)
            XCTAssertEqual(f.runtime.recent.map(\.text), ["synthetic caption"])
            XCTAssertEqual(Array(f.voice.events.suffix(2)), [
                .assistant(AssistantVADPrototype.status(.start)),
                .assistant(try AssistantTextPrototype.asrText("synthetic caption", isFinal: true))])

            await stopAndFlush(f)
            XCTAssertEqual(Array(f.voice.events.suffix(2)), stopCommands)
            XCTAssertFalse(f.voice.ownsVoice)
        }
    }

    @MainActor func testWakeupSubmissionFailureReleasesOwnershipWithoutStartingASR() async throws {
        let f = try fixture()
        f.voice.failWakeup = true
        await f.runtime.arm(f.runtime.options)?.value
        await waitForIdle(f.runtime)
        XCTAssertEqual(f.voice.wakeupAttempts, 1)
        XCTAssertTrue(f.voice.events.isEmpty)
        XCTAssertFalse(f.voice.ownsVoice)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertTrue(f.runtime.error?.contains("唤醒初始化") == true)
        XCTAssertFalse(f.runtime.status.contains("已待命"))
        f.emit(1)
        XCTAssertEqual(f.provider.starts, 0)
    }

    @MainActor func testCancelOrDisconnectDuringPreparationNeverInitializesWakeup() async throws {
        for cancel in [true, false] {
            let f = try fixture()
            let preparation = try XCTUnwrap(f.runtime.arm(f.runtime.options))
            XCTAssertEqual(f.runtime.phase, .preparing)
            f.emit(1) // A callback queued before initialization is not consent to start.
            if cancel { f.runtime.stop() } else { f.voice.deviceID = nil }
            await preparation.value
            await waitForIdle(f.runtime)
            XCTAssertTrue(f.voice.events.isEmpty)
            XCTAssertEqual(f.voice.wakeupAttempts, 0)
            XCTAssertEqual(f.provider.starts, 0)
            XCTAssertFalse(f.voice.ownsVoice)
        }
    }

    @MainActor func testCancellationDuringInitializationDoesNotRestoreArmedState() async throws {
        let f = try fixture()
        f.voice.onWakeup = { [weak runtime = f.runtime] in runtime?.stop() }
        await f.runtime.arm(f.runtime.options)?.value
        await waitForIdle(f.runtime)
        f.emit(1)
        XCTAssertEqual(f.voice.events, [.wakeup("test-glasses")])
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertFalse(f.voice.ownsVoice)
        XCTAssertFalse(f.runtime.status.contains("已待命"))
    }

    @MainActor func testOldWrongDeviceAndFutureWakeEventsCannotStartNewSession() async throws {
        let f = try fixture()
        await f.runtime.arm(f.runtime.options)?.value
        let oldText = f.provider.onText
        f.time.value += 0.1
        let oldArrival = f.time.value
        await stopAndFlush(f) // Stopping armed captions sends no recording command.
        XCTAssertEqual(f.voice.events, [.wakeup("test-glasses")])
        f.time.value += 0.1
        await f.runtime.arm(f.runtime.options)?.value
        f.emit(1, arrival: oldArrival) // Still under the 500 ms age limit, but from the old arm.
        f.emit(8, arrival: oldArrival)
        f.emit(1, arrival: f.time.value + 0.1)
        f.emit(1, device: "other-glasses")
        XCTAssertEqual(f.runtime.phase, .armed)
        XCTAssertEqual(f.provider.starts, 0)

        f.emit(1)
        oldText?("late old session result", true)
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertTrue(f.runtime.recent.isEmpty)
        await stopAndFlush(f)
        let sent = f.voice.events
        f.emit(1); f.emit(3, audio: Data([1, 2]))
        f.provider.onText?("late stopped result", true)
        XCTAssertEqual(f.voice.events, sent)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertTrue(f.provider.audio.isEmpty)
        XCTAssertTrue(f.runtime.recent.isEmpty)
    }

    @MainActor func testExpiredArmAndDisconnectedGlassesRequireManualRestart() async throws {
        let f = try fixture()
        await f.runtime.arm(f.runtime.options)?.value
        f.time.value += 300
        f.emit(1) // Timer has not run yet; an expired arm still must reject this wake.
        await waitForIdle(f.runtime)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.voice.events.count, 1)

        await f.runtime.arm(f.runtime.options)?.value
        f.voice.deviceID = nil
        f.runtime.tick()
        await waitForIdle(f.runtime)
        f.voice.deviceID = "test-glasses"
        f.runtime.tick(); f.emit(1)
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.voice.events.count, 2)
        XCTAssertFalse(f.voice.ownsVoice)
    }

    @MainActor func testRecorderSubmissionFailureOrMissingDecoderStopsRealWakeWithoutASR() async throws {
        for missingDecoder in [true, false] {
            let f = try fixture()
            f.decoder.available = !missingDecoder
            f.voice.failStartAudio = !missingDecoder
            await f.runtime.arm(f.runtime.options)?.value
            f.emit(1)
            await waitForIdle(f.runtime)
            XCTAssertEqual(f.provider.starts, 0)
            XCTAssertEqual(f.voice.events, [.wakeup("test-glasses")] + stopCommands)
            XCTAssertFalse(f.voice.ownsVoice)
        }
    }

    @MainActor func testGlassesExitStopsAudioAndDoesNotAutomaticallyRearm() async throws {
        let f = try fixture()
        await f.runtime.arm(f.runtime.options)?.value
        f.emit(1); f.emit(8)
        await waitForIdle(f.runtime)
        XCTAssertEqual(Array(f.voice.events.suffix(2)), stopCommands)
        XCTAssertEqual(f.provider.stops, 1)
        let sent = f.voice.events
        f.runtime.tick(); f.emit(1)
        XCTAssertEqual(f.voice.events, sent)
        XCTAssertEqual(f.provider.starts, 1)
    }

    @MainActor private var stopCommands: [CaptionTestDevice.Event] { [
        .assistant(AssistantRecorderPrototype.control(start: false)),
        .assistant(AssistantExitPrototype.normalExit())
    ] }
    @MainActor private func fixture(_ service: SpeechService = .deepgram) throws -> CaptionRuntimeFixture {
        let f = try CaptionRuntimeFixture(service)
        addTeardownBlock { await self.cleanUp(f) }
        return f
    }
    @MainActor private func waitForIdle(_ runtime: CaptionRuntime) async {
        guard runtime.phase != .idle else { return }
        let done = expectation(description: "caption journal flushed")
        let subscription = runtime.$phase.filter { $0 == .idle }.first().sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(runtime.phase, .idle)
    }
    @MainActor private func stopAndFlush(_ f: CaptionRuntimeFixture) async {
        f.runtime.stop()
        await waitForIdle(f.runtime)
    }
    @MainActor private func cleanUp(_ f: CaptionRuntimeFixture) async {
        await stopAndFlush(f)
        f.defaults.removePersistentDomain(forName: f.suite)
        try? FileManager.default.removeItem(at: f.root)
    }
}

@MainActor private final class CaptionRuntimeFixture {
    let suite = "caption-runtime-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let credentials = MemorySpeechCredentials()
    let time = CaptionTestTime()
    let provider = CaptionTestProvider()
    let decoder = CaptionTestDecoder()
    let voice: CaptionTestDevice
    let runtime: CaptionRuntime
    init(_ service: SpeechService) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let settings = SpeechSettingsStore(defaults: defaults, credentials: credentials, allowsCredentialChanges: true)
        var config = SpeechConfiguration(); config.service = service
        config.region = service == .azure ? "eastus" : ""
        config.aliyunHost = service == .aliyun ? "tenant.example.aliyuncs.com" : ""
        XCTAssertTrue(settings.save(config, asrKey: "synthetic-test-only"))
        voice = CaptionTestDevice(speech: settings)
        let provider = provider, decoder = decoder, time = time
        runtime = CaptionRuntime(voice: voice, defaults: defaults, root: root,
            makeProvider: { selected in XCTAssertEqual(selected, service); return provider },
            makeDecoder: { decoder.available ? decoder : nil },
            uptime: { time.value }, scheduleTimers: false)
    }
    func emit(_ type: UInt32, audio: Data? = nil, arrival: TimeInterval? = nil, device: String = "test-glasses") {
        voice.onCaptionEnvelope?(device, type, audio, arrival ?? time.value)
    }
}

private final class CaptionTestTime { var value: TimeInterval = 100 }
private final class CaptionTestDecoder: CaptionAudioDecoder {
    var available = true
    var packets: [Data] = []
    let pcm = Data(repeating: 1, count: 320) // Synthetic bytes; no microphone or native Opus decoder.
    func decode(_ audio: Data) -> CaptionDecodedAudio? {
        packets.append(audio)
        return CaptionDecodedAudio(pcm: pcm, frames: 1, voicedMask: 1)
    }
    func reset() {}
}

@MainActor private final class CaptionTestProvider: CaptionASRProvider {
    var onText: ((String, Bool) -> Void)?
    var onEndpoint: (() -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((CaptionConnectionFailure) -> Void)?
    var started: CaptionOptions?
    var starts = 0, stops = 0
    var audio: [Data] = []
    func start(options: CaptionOptions, key: String) { started = options; starts += 1; onReady?() }
    func append(_ pcm: Data) { audio.append(pcm) }
    func stop() { stops += 1 }
}

@MainActor private final class CaptionTestDevice: CaptionDeviceTransport {
    enum Event: Equatable { case wakeup(String), assistant(Data) }
    let speech: SpeechSettingsStore
    let supportsDevice = true
    var deviceID: String? = "test-glasses"
    var enabled = false
    var featureIsBusy: (() -> Bool)?
    var onCaptionEnvelope: ((String, UInt32, Data?, TimeInterval) -> Void)?
    var onCaptionInputLoss: ((String) -> Void)?
    var ownsVoice = false, failWakeup = false, failStartAudio = false
    var onWakeup: (() -> Void)?
    var wakeupAttempts = 0
    var events: [Event] = []
    init(speech: SpeechSettingsStore) { self.speech = speech }
    func prepare() {}
    func ownVoiceForCaptions(_ owns: Bool) { ownsVoice = owns }
    func sendCaptionWakeup(target: String) throws {
        wakeupAttempts += 1
        guard ownsVoice, deviceID == target, !failWakeup else { throw DeviceFeatureError.disconnected }
        events.append(.wakeup(target)); onWakeup?()
    }
    func sendCaption(target: String, payload: Data) throws {
        guard ownsVoice, deviceID == target else { throw DeviceFeatureError.disconnected }
        if failStartAudio, payload == AssistantRecorderPrototype.control(start: true) { throw DeviceFeatureError.disconnected }
        events.append(.assistant(payload))
    }
}
