import Foundation
import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class SpeechPrompterRuntimeTests: XCTestCase {
    @MainActor func testRecognitionCreatesGradualScrollInsteadOfJumpingToSentenceEnd() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone)).value
        f.provider.onText?(f.firstSentence, true)
        let target = f.runtime.confirmedUTF8Offset
        XCTAssertGreaterThan(target, 0)
        XCTAssertEqual(f.runtime.displayedUTF8Offset, 0)
        XCTAssertTrue(f.transport.seeks.isEmpty)
        for _ in 0..<6 {
            let previous = f.runtime.displayedUTF8Offset
            f.clock.now += 0.15; f.runtime.tick()
            XCTAssertGreaterThanOrEqual(f.runtime.displayedUTF8Offset, previous)
            XCTAssertLessThanOrEqual(f.runtime.displayedUTF8Offset - previous, 6)
        }
        XCTAssertGreaterThan(f.runtime.displayedUTF8Offset, 0)
        XCTAssertLessThan(f.runtime.displayedUTF8Offset, target)
        XCTAssertTrue(f.transport.seeks.allSatisfy { $0.page == $0.highlight && $0.page % 3 == 0 })
    }

    @MainActor func testRecommendedSettingsAcceptImperfectEnglishWithoutImmediatePageJump() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        let tuning = PrompterSettingsStore(defaults: f.defaults)
        tuning.reset()
        let document = PrompterManuscript(title: "English rehearsal",
            text: "Today we discuss our project and explain the next steps.")
        try await XCTUnwrap(f.runtime.start(document: document, output: .phone, input: .iPhone)).value
        f.provider.onText?("Today we discus aur proget and esplain the nest steps", true)
        XCTAssertGreaterThan(f.runtime.confirmedUTF8Offset, 0)
        XCTAssertEqual(f.runtime.displayedUTF8Offset, 0)
        f.clock.now += 0.2; f.runtime.tick()
        XCTAssertGreaterThan(f.runtime.displayedUTF8Offset, 0)
        XCTAssertLessThan(f.runtime.displayedUTF8Offset, f.runtime.confirmedUTF8Offset)
    }

    @MainActor func testTuningChangesApplyWithoutRestartingMicrophoneOrRecognition() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone)).value
        f.provider.onText?(f.firstSentence, true)
        f.clock.now += 0.2; f.runtime.tick()
        let shown = f.runtime.displayedUTF8Offset
        let tuning = PrompterSettingsStore(defaults: f.defaults)
        tuning.update(\.scrollUnitsPerSecond, 8)
        f.runtime.reloadTuning()
        XCTAssertEqual(f.runtime.displayedUTF8Offset, shown)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, shown)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.microphone.starts, 1)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.microphone.stops, 0)
        XCTAssertEqual(f.runtime.phase, .listening)
    }

    @MainActor func testSilentPCMStopsPendingScrollAndManualAssistStillSends() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone)).value
        f.provider.onText?(f.firstSentence, true)
        f.clock.now += 0.2; f.runtime.tick()
        let shown = f.runtime.displayedUTF8Offset
        f.clock.now += 2.1
        f.microphone.onPCM?(Data(repeating: 0, count: 640))
        f.runtime.tick()
        XCTAssertEqual(f.runtime.displayedUTF8Offset, shown)
        f.runtime.assist(toUTF8Offset: f.secondStart)
        XCTAssertEqual(f.transport.seeks.last?.page, f.secondStart)
        XCTAssertEqual(f.transport.seeks.last?.highlight, f.secondStart)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.microphone.stops, 0)
    }
    @MainActor func testLongAudioGapHoldsWithoutClosingRecognitionAndFreshAudioCanResume() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone)).value
        f.provider.onText?(f.firstSentence, true)
        let anchor = f.runtime.confirmedUTF8Offset
        f.clock.now += 20; f.runtime.tick()
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, anchor)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.microphone.stops, 0)
        f.provider.onText?(f.secondSentence, true) // Old results during the gap do not move.
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, anchor)
        f.microphone.onPCM?(Data(repeating: 1, count: 640))
        f.provider.onText?(f.secondSentence, true)
        XCTAssertEqual(f.runtime.followState, .finished)
        XCTAssertEqual(f.microphone.starts, 1)
    }

    @MainActor func testUnmappedEyeSwipeHoldsAndKeepsMicrophoneAndRecognizerAlive() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone)).value
        f.provider.onText?("今天我们介绍", false)
        f.provider.onText?("今天我们介绍产品", false)
        let anchor = f.runtime.confirmedUTF8Offset
        let seeks = f.transport.seeks.count
        f.transport.onPositionUnavailable?()
        f.clock.now += 1; f.runtime.tick()
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, anchor)
        XCTAssertEqual(f.transport.seeks.count, seeks)
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.microphone.stops, 0)
    }

    @MainActor func testPhoneAssistKeepsCaptureAndRecognizerRunningAndThenFollowsNearbySpeech() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone)).value
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertEqual(f.microphone.starts, 1)
        f.runtime.assist(toUTF8Offset: f.secondStart)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, f.secondStart)
        XCTAssertEqual(f.runtime.followState, .waiting)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.microphone.stops, 0)
        let pcm = Data(repeating: 1, count: 640)
        f.microphone.onPCM?(pcm)
        XCTAssertEqual(f.provider.audio, [pcm])
        f.provider.onText?(f.secondSentence, true)
        XCTAssertGreaterThan(f.runtime.confirmedUTF8Offset, f.secondStart)
        XCTAssertEqual(f.runtime.followState, .finished)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.microphone.stops, 0)
    }

    @MainActor func testExplicitPauseStillRecognizesAndCapturesButNeedsFreshSpeechAfterResume() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone)).value
        f.runtime.pauseFollowing()
        f.provider.onText?(f.firstSentence, true)
        f.microphone.onPCM?(Data(repeating: 1, count: 640))
        XCTAssertEqual(f.runtime.followState, .paused)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, 0)
        XCTAssertEqual(f.runtime.recognitionText, f.firstSentence)
        XCTAssertEqual(f.provider.audio.count, 1)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.microphone.stops, 0)
        f.runtime.resumeFollowing()
        f.provider.onText?(f.firstSentence, true) // Already received while paused.
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, 0)
        f.provider.onText?(f.firstSentence + "随后", true)
        XCTAssertGreaterThan(f.runtime.confirmedUTF8Offset, 0)
    }

    @MainActor func testInterruptionAndUncertainSpeechHoldPositionWithoutStoppingListening() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone)).value
        f.provider.onText?(f.firstSentence, true)
        let anchor = f.runtime.confirmedUTF8Offset
        XCTAssertGreaterThan(anchor, 0)
        f.provider.onText?("请问这个设备大概多少钱", true)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, anchor)
        XCTAssertEqual(f.runtime.followState, .uncertain)
        f.clock.now += 3
        f.runtime.tick()
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, anchor)
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertEqual(f.microphone.stops, 0)
        f.provider.onText?(f.secondSentence, true)
        XCTAssertEqual(f.runtime.followState, .finished)
    }

    @MainActor func testEyeSwipeAssistsWithoutSendingBackSeekOrRestartingAudio() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .glasses)).value
        XCTAssertEqual(f.transport.scrollModes, [1])
        let seeksBefore = f.transport.seeks.count
        f.transport.onProgress?(f.secondStart, f.secondStart)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, f.secondStart)
        XCTAssertEqual(f.transport.seeks.count, seeksBefore)
        XCTAssertEqual(f.runtime.followState, .waiting)
        f.transport.onAudio?(Data([1]), 1)
        f.transport.onAudio?(Data([1]), 1) // Duplicate sequence is not audio twice.
        XCTAssertEqual(f.provider.audio.count, 1)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.decoder.resets, 1)
        f.provider.onText?(f.secondSentence, true)
        XCTAssertEqual(f.runtime.followState, .finished)
    }

    @MainActor func testProgrammaticSeekEchoDoesNotReanchorOrEraseSpeechEvidence() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        f.transport.echoSeekSynchronously = true
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone)).value
        f.provider.onText?("今天我们介绍", false)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, 0)
        f.provider.onText?("今天我们介绍产品", false)
        let confirmed = "今天我们介绍产品".utf8.count
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, confirmed)
        f.clock.now += 0.6
        f.runtime.tick() // Pending seek synchronously invokes onProgress.
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, confirmed)
        XCTAssertGreaterThan(f.runtime.displayedUTF8Offset, 0)
        XCTAssertLessThan(f.runtime.displayedUTF8Offset, confirmed)
        XCTAssertEqual(f.transport.seeks.last?.page, f.runtime.displayedUTF8Offset)
        XCTAssertEqual(f.transport.seeks.last?.highlight, f.runtime.displayedUTF8Offset)
        f.provider.onText?("今天我们介绍产品的", false)
        XCTAssertGreaterThan(f.runtime.confirmedUTF8Offset, confirmed)
        XCTAssertEqual(f.microphone.starts, 1)
        XCTAssertEqual(f.provider.starts, 1)
    }

    @MainActor func testStopRejectsLateProviderMicrophoneAndEyeCallbacks() async throws {
        let f = fixture()
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone)).value
        let text = f.provider.onText, ready = f.provider.onReady, failure = f.provider.onFailure
        let pcm = f.microphone.onPCM, position = f.transport.onProgress, eyeAudio = f.transport.onAudio
        f.runtime.stop()
        let anchor = f.runtime.confirmedUTF8Offset
        text?(f.firstSentence, true); ready?(); failure?(.connection)
        pcm?(Data(repeating: 1, count: 640)); position?(f.secondStart, f.secondStart); eyeAudio?(Data([1]), 1)
        f.clock.now += 3; f.runtime.tick()
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, anchor)
        XCTAssertTrue(f.runtime.recognitionText.isEmpty)
        XCTAssertTrue(f.provider.audio.isEmpty)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.provider.stops, 1)
        XCTAssertEqual(f.microphone.stops, 1)
        XCTAssertEqual(f.transport.stops, 1)
    }

    @MainActor func testRecognizerReconnectBuffersPCMAndRejectsPreviousGeneration() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone)).value
        f.provider.onText?("今天我们介绍", false)
        let oldText = f.provider.onText, oldReady = f.provider.onReady
        f.provider.onFailure?(.connection)
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, 0)
        XCTAssertEqual(f.microphone.stops, 0)
        XCTAssertEqual(f.provider.stops, 1)
        let pcm = Data(repeating: 1, count: 640)
        f.microphone.onPCM?(pcm)
        XCTAssertTrue(f.provider.audio.isEmpty)
        oldText?(f.firstSentence, true); oldReady?()
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, 0)
        XCTAssertTrue(f.provider.audio.isEmpty)
        f.clock.now += 1.1; f.runtime.tick()
        XCTAssertEqual(f.provider.starts, 2)
        XCTAssertEqual(f.provider.audio, [pcm])
        XCTAssertEqual(f.runtime.confirmedUTF8Offset, 0)
        f.provider.onText?(f.firstSentence, true)
        XCTAssertGreaterThan(f.runtime.confirmedUTF8Offset, 0)
        XCTAssertEqual(f.microphone.starts, 1)
        XCTAssertEqual(f.microphone.stops, 0)
    }

    @MainActor func testReadingPositionPersistenceIsThrottledAndManualAssistForcesSave() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        var saved: [(UUID, Int)] = []
        f.runtime.onPosition = { saved.append(($0, $1)) }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone)).value
        f.provider.onText?("今天我们介绍", false)
        f.provider.onText?("今天我们介绍产品", false)
        f.provider.onText?("今天我们介绍产品的工作", false)
        XCTAssertTrue(saved.isEmpty)
        f.clock.now += 1; f.runtime.tick()
        XCTAssertTrue(saved.isEmpty)
        f.clock.now += 1.1; f.runtime.tick()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.0, f.document.id)
        XCTAssertEqual(saved.first?.1, f.runtime.displayedUTF8Offset)
        f.runtime.assist(toUTF8Offset: f.secondStart)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.last?.1, f.secondStart)
        f.runtime.stop()
        XCTAssertEqual(saved.count, 2) // Nothing changed after the forced save.
    }

    @MainActor func testCancelBeforeStartupDoesNotOpenGlassesOrCaptureMicrophone() async throws {
        let f = fixture()
        let task = try XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone))
        task.cancel()
        await task.value
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(f.transport.prepares, 0)
        XCTAssertEqual(f.transport.starts, 0)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.microphone.starts, 0)
    }

    @MainActor func testEndingBeforeStartupTaskRunsCannotOpenOrphanGlassesSession() async throws {
        let f = fixture()
        let task = try XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone))
        f.runtime.stop()
        await task.value
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(f.transport.prepares, 0)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.microphone.starts, 0)
        XCTAssertNil(f.transport.sessionID)
    }

    @MainActor func testStartupAuthenticationFailureStopsBeforeMicrophoneStarts() async throws {
        let f = fixture()
        f.provider.failureOnStart = .authentication
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone)).value
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertNotNil(f.runtime.error)
        XCTAssertEqual(f.microphone.starts, 0)
        XCTAssertEqual(f.transport.starts, 0)
        XCTAssertEqual(f.transport.stops, 1)
        XCTAssertEqual(f.provider.stops, 1)
    }

    @MainActor func testRetryableStartupFailureRecoversBeforeOpeningMicrophone() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        f.provider.failureOnStart = .connection
        let firstStart = expectation(description: "Initial recognizer start")
        f.provider.onStart = { if f.provider.starts == 1 { firstStart.fulfill() } }
        let task = try XCTUnwrap(f.runtime.start(document: f.document, output: .phone, input: .iPhone))
        await fulfillment(of: [firstStart], timeout: 2)
        XCTAssertEqual(f.runtime.phase, .preparing)
        XCTAssertEqual(f.microphone.starts, 0)
        f.clock.now += 1.1
        await task.value
        XCTAssertEqual(f.provider.starts, 2)
        XCTAssertEqual(f.provider.stops, 1)
        XCTAssertEqual(f.microphone.starts, 1)
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertNil(f.runtime.error)
    }

    @MainActor func testGlassesOpeningCompletesBeforeMicrophoneStartsAndPrestartAudioIsIgnored() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        f.transport.autoStarted = false
        let startRequested = expectation(description: "Glasses start requested")
        f.transport.onStart = { startRequested.fulfill() }
        f.transport.onPrepare = { f.transport.onAudio?(Data([1]), 1) }
        let task = try XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone))
        await fulfillment(of: [startRequested], timeout: 2)
        XCTAssertEqual(f.microphone.starts, 0)
        XCTAssertEqual(f.runtime.phase, .preparing)
        XCTAssertNil(f.runtime.error)
        f.transport.started = true
        await task.value
        XCTAssertEqual(f.microphone.starts, 1)
        XCTAssertEqual(f.runtime.phase, .listening)
    }

    @MainActor func testPendingFileTransferPublishesItsStatusBeforeStartingRecognitionOrCapture() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        f.transport.autoPrepared = false
        f.transport.preparationStatus = "提词稿传输 42% · 等待完整收稿确认"
        let prepareRequested = expectation(description: "Manuscript transfer requested")
        f.transport.onPrepare = { prepareRequested.fulfill() }
        let task = try XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone))
        await fulfillment(of: [prepareRequested], timeout: 2)

        XCTAssertEqual(f.runtime.phase, .preparing)
        XCTAssertEqual(f.runtime.status, f.transport.preparationStatus)
        XCTAssertNil(f.runtime.error)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.microphone.starts, 0)
        XCTAssertEqual(f.transport.starts, 0)

        f.transport.prepared = true
        await task.value
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.microphone.starts, 1)
        XCTAssertEqual(f.transport.starts, 1)
    }

    @MainActor func testLateFilePreparationAfterStopCannotStartRecognitionOrCapture() async throws {
        let f = fixture()
        f.transport.autoPrepared = false
        f.transport.preparationStatus = "正在向眼镜传输提词稿"
        let prepareRequested = expectation(description: "Pending manuscript transfer requested")
        f.transport.onPrepare = { prepareRequested.fulfill() }
        let task = try XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .iPhone))
        await fulfillment(of: [prepareRequested], timeout: 2)
        XCTAssertEqual(f.runtime.phase, .preparing)
        XCTAssertEqual(f.provider.starts, 0)

        f.runtime.stop()
        f.transport.prepared = true // Completion of the transfer that was just stopped.
        await task.value

        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.microphone.starts, 0)
        XCTAssertEqual(f.transport.starts, 0)
        XCTAssertEqual(f.transport.stops, 1)
        XCTAssertNil(f.runtime.error)
    }

    @MainActor func testEyeMicrophoneIgnoresAudioBeforeDecoderAndOpeningAreReady() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        f.transport.onPrepare = { f.transport.onAudio?(Data([1]), 1) }
        try await XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .glasses)).value
        XCTAssertNil(f.runtime.error)
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertTrue(f.provider.audio.isEmpty)
        f.transport.onAudio?(Data([1]), 1)
        XCTAssertEqual(f.provider.audio.count, 1)
    }

    @MainActor func testEyeAudioBeforeGlassesStartAcknowledgementDoesNotConsumeSequence() async throws {
        let f = fixture()
        defer { f.runtime.stop() }
        f.transport.autoStarted = false
        let startRequested = expectation(description: "Eye microphone start requested")
        f.transport.onStart = { startRequested.fulfill() }
        let task = try XCTUnwrap(f.runtime.start(document: f.document, output: .glasses, input: .glasses))
        await fulfillment(of: [startRequested], timeout: 2)
        f.transport.onAudio?(Data([1]), 1)
        XCTAssertTrue(f.provider.audio.isEmpty)
        XCTAssertNil(f.runtime.error)
        f.transport.started = true
        await task.value
        f.transport.onAudio?(Data([1]), 1)
        XCTAssertEqual(f.provider.audio.count, 1)
    }

    @MainActor func testUnavailableOrInvalidInputDoesNotBeginRecognizerOrCapture() {
        let f = fixture()
        f.availability.value = false
        XCTAssertNil(f.runtime.start(document: f.document, output: .phone, input: .iPhone))
        f.availability.value = true
        XCTAssertNil(f.runtime.start(document: f.document, output: .phone, input: .glasses))
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.microphone.starts, 0)
        XCTAssertEqual(f.transport.prepares, 0)
        XCTAssertEqual(f.runtime.phase, .idle)
    }

    @MainActor private func fixture() -> Fixture {
        let result = Fixture()
        addTeardownBlock { await self.cleanup(result) }
        return result
    }

    @MainActor private func cleanup(_ fixture: Fixture) {
        fixture.runtime.stop()
        fixture.defaults.removePersistentDomain(forName: fixture.name)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @MainActor private final class Fixture {
        let name = "speech-prompter-tests-" + UUID().uuidString
        let root: URL, defaults: UserDefaults
        let store: CompanionStore, settings: SubtitleSettingsStore, runtime: SpeechPrompterRuntime
        let provider = Provider(), microphone = Microphone(), transport = Transport()
        let decoder = Decoder(), vault = Vault(), clock = Clock(), availability = Availability()
        let firstSentence = "今天我们介绍产品的工作原理"
        let secondSentence = "随后讨论具体应用以及实施方法"
        let document: PrompterManuscript
        var secondStart: Int { (firstSentence + "。\n").utf8.count }
        init() {
            defaults = UserDefaults(suiteName: name)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            store = CompanionStore(defaults: defaults, recordingRoot: root.appendingPathComponent("recordings"),
                                   archiveRoot: root.appendingPathComponent("archive"))
            let provider = provider
            settings = SubtitleSettingsStore(defaults: defaults, credentials: vault, allowsChanges: true,
                                             factory: { _ in provider })
            var options = CaptionOptions(); options.service = .deepgram
            XCTAssertTrue(settings.save(options, key: "synthetic-test-only"))
            // Existing lifecycle tests retain their original strict matching
            // assumptions. Recommended product tuning has separate coverage.
            var tuning = PrompterTuning()
            tuning.minimumSimilarity = 0.8; tuning.minMatchedUnits = 6
            tuning.requiredStableUpdates = 2; tuning.maxForwardUnits = 64
            tuning.lookAheadUnits = 160
            XCTAssertTrue(PrompterSettingsStore(defaults: defaults).save(tuning))
            document = PrompterManuscript(title: "合成演讲稿", text: firstSentence + "。\n" + secondSentence + "。")
            let microphone = microphone, decoder = decoder, clock = clock, availability = availability
            runtime = SpeechPrompterRuntime(settings: settings, features: store.features,
                available: { availability.value }, defaults: defaults, transport: transport,
                makeMicrophone: { microphone }, makeDecoder: { decoder }, uptime: { clock.now }, scheduleTimers: false)
        }
    }

    private final class Clock { var now: TimeInterval = 100 }
    private final class Availability { var value = true }
    private final class Decoder: SubtitlePCMDecoder {
        var resets = 0
        func decode(_ packet: Data) -> Data? { packet.isEmpty ? nil : Data(repeating: 1, count: 640) }
        func reset() { resets += 1 }
    }
    private final class Vault: SubtitleCredentialStorage {
        private var keys: [String: String] = [:]
        func key(for options: CaptionOptions) -> String? { keys[options.credentialService + options.credentialAccount] }
        func save(_ key: String, for options: CaptionOptions) throws { keys[options.credentialService + options.credentialAccount] = key }
        func remove(for options: CaptionOptions) throws { keys.removeValue(forKey: options.credentialService + options.credentialAccount) }
    }
    @MainActor private final class Provider: CaptionASRProvider {
        var onText: ((String, Bool) -> Void)?, onEndpoint: (() -> Void)?
        var onReady: (() -> Void)?, onFailure: ((CaptionConnectionFailure) -> Void)?
        var starts = 0, stops = 0, audio: [Data] = []
        var failureOnStart: CaptionConnectionFailure?
        var onStart: (() -> Void)?
        func start(options: CaptionOptions, key: String) {
            starts += 1
            let failure = failureOnStart; failureOnStart = nil
            if let failure { onFailure?(failure) } else { onReady?() }
            onStart?()
        }
        func append(_ pcm: Data) { audio.append(pcm) }
        func stop() { stops += 1 }
    }
    @MainActor private final class Microphone: SpeechPrompterMicrophone {
        var onPCM: ((Data) -> Void)?, onFailure: ((String) -> Void)?
        var starts = 0, stops = 0
        func start(input: SpeechPrompterRuntime.Input) async throws -> String { starts += 1; return "合成麦克风" }
        func stop() { stops += 1 }
    }
    @MainActor private final class Transport: SpeechPrompterTransport {
        var deviceID: String? = "synthetic-glasses", ready = true, sessionID: String?
        var prepared = false, started = false, errorMessage: String?
        var preparationStatus = ""
        var onProgress: ((Int, Int) -> Void)?, onControl: ((UInt32) -> Void)?
        var onAudio: ((Data, Int?) -> Void)?, onFailure: ((String) -> Void)?
        var onPositionUnavailable: (() -> Void)?
        var prepares = 0, starts = 0, stops = 0, scrollModes: [Int] = []
        var seeks: [(page: Int, highlight: Int)] = []
        var autoPrepared = true, autoStarted = true, echoSeekSynchronously = false
        var onStart: (() -> Void)?, onPrepare: (() -> Void)?
        func prepare(text: String, title: String, scrollMode: Int, initialOffset: Int) -> Bool {
            prepares += 1; sessionID = UUID().uuidString; prepared = autoPrepared
            scrollModes.append(scrollMode); onPrepare?(); return true
        }
        func start() -> Bool { starts += 1; started = autoStarted; onStart?(); return true }
        func seek(page: Int, highlight: Int) -> Bool {
            seeks.append((page, highlight))
            if echoSeekSynchronously { onProgress?(page, highlight) }
            return true
        }
        func stop() { stops += 1; sessionID = nil; prepared = false; started = false }
    }
}
