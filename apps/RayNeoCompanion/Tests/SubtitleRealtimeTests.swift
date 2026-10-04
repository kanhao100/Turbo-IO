import XCTest
import RayNeoProtocol
import RayNeoCaptions
@testable import RayNeoCompanion

final class SubtitleRealtimeTests: XCTestCase {
    @MainActor func testTranslationBeforeDisplayACKWaitsForTheLensToOpen() async throws {
        let translator = Translator()
        let f = Fixture(.deepgram, rolling: true, translator: translator)
        addTeardownBlock { await self.cleanup(f) }
        XCTAssertTrue(f.settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
            retention: .untilNextSentence, displayLayout: .rolling,
            rollingConfiguration: CaptionRollingConfiguration(columns: 16)))
        await f.runtime.start()?.value
        let sid = try f.sid()
        f.feed(2, sid: sid, code: 1)
        let requested = expectation(description: "translation before display ACK")
        translator.onRequest = { requested.fulfill() }
        f.provider.onText?("original", true)
        await fulfillment(of: [requested], timeout: 3)
        translator.onRequest = nil
        let archived = expectation(description: "early translation archived")
        f.writer.onTranslation = { archived.fulfill() }
        translator.complete("甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉")
        await fulfillment(of: [archived], timeout: 3)
        let first = f.runtime.displayTranslationText
        f.clock.now += 3; f.runtime.tick()
        XCTAssertEqual(f.runtime.displayTranslationText, first)
        XCTAssertFalse(try f.types().contains(5))
        f.feed(8, sid: sid, code: 1)
        XCTAssertTrue(try f.lensText().contains("甲乙丙丁戊己庚辛"))
        f.clock.now += 1.4; f.runtime.tick()
        XCTAssertEqual(f.runtime.displayTranslationText, first)
    }

    @MainActor func testRollingIgnoresLegacySourceGateAndRetainsDraftWhenSwitchingLayout() async throws {
        let f = Fixture(.deepgram, rolling: true, translator: Translator())
        addTeardownBlock { await self.cleanup(f) }
        XCTAssertTrue(f.settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
            retention: .untilNextSentence, showLiveSourceDuringTranslation: false, displayLayout: .rolling))
        await f.runtime.start()?.value
        let sid = try f.sid()
        f.feed(2, sid: sid, code: 1); f.feed(8, sid: sid, code: 1)
        f.provider.onText?("latest draft", false)
        XCTAssertEqual(f.runtime.displaySourceText, "latest draft")
        XCTAssertTrue(f.settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
            retention: .untilNextSentence, displayLayout: .sentence))
        f.clock.now += 0.5; f.runtime.tick()
        f.provider.onText?("revised draft", false)
        XCTAssertTrue(f.settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
            retention: .untilNextSentence, displayLayout: .rolling))
        f.clock.now += 0.5; f.runtime.tick()
        XCTAssertEqual(f.runtime.displaySourceText, "revised draft")
    }

    @MainActor func testRollingTranslationSurvivesNewSourceAndNextPartial() async throws {
        let translator = Translator()
        let f = Fixture(.deepgram, rolling: true, translator: translator)
        addTeardownBlock { await self.cleanup(f) }
        await f.runtime.start()?.value
        let sid = try f.sid()
        f.feed(2, sid: sid, code: 1); f.feed(8, sid: sid, code: 1)
        let requested = expectation(description: "first translation requested")
        translator.onRequest = { requested.fulfill() }
        f.provider.onText?("first source", true)
        await fulfillment(of: [requested], timeout: 3)
        translator.onRequest = nil
        f.clock.now += 0.6
        f.provider.onText?("second source is growing", false)
        let translated = expectation(description: "translation archived")
        f.writer.onTranslation = { translated.fulfill() }
        translator.complete("第一段译文")
        await fulfillment(of: [translated], timeout: 3)
        f.clock.now += 0.6; f.runtime.tick()
        XCTAssertTrue(f.runtime.displaySourceText.contains("second"))
        XCTAssertEqual(f.runtime.displayTranslationText, "第一段译文")
        let rows = try f.lensText().components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.prefix(3).joined().contains("second"))
        XCTAssertTrue(rows.suffix(2).joined().contains("第一段译文"))
        f.provider.onText?("second source has been revised", false)
        XCTAssertEqual(f.runtime.displayTranslationText, "第一段译文")
        XCTAssertFalse(f.runtime.displaySourceText.contains("growing"))
    }

    @MainActor func testLongRollingTranslationShowsEveryStepAndHonorsLensReadingTime() async throws {
        let translator = Translator()
        let f = Fixture(.deepgram, rolling: true, translator: translator)
        addTeardownBlock { await self.cleanup(f) }
        let configuration = CaptionRollingConfiguration(sourceLines: 3, columns: 16)
        XCTAssertTrue(f.settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
            retention: .untilNextSentence, translationMinimumVisibleSeconds: 1.5,
            displayLayout: .rolling, rollingConfiguration: configuration))
        await f.runtime.start()?.value
        let sid = try f.sid()
        f.feed(2, sid: sid, code: 1); f.feed(8, sid: sid, code: 1)
        let requested = expectation(description: "long translation requested")
        translator.onRequest = { requested.fulfill() }
        f.provider.onText?("original", true)
        await fulfillment(of: [requested], timeout: 3)
        translator.onRequest = nil
        f.provider.onText?("current speech", false)
        let result = "甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥天地玄黄宇宙洪荒"
        let archived = expectation(description: "long translation archived")
        f.writer.onTranslation = { archived.fulfill() }
        translator.complete(result)
        await fulfillment(of: [archived], timeout: 3)
        // The first source frame used the current 500 ms transport slot. Reading
        // time must start when the first translated frame is submitted later.
        f.clock.now += 0.5; f.runtime.tick()
        var shown = [try f.lensText()]
        let firstTranslation = f.runtime.displayTranslationText
        f.clock.now += 1.4; f.runtime.tick()
        XCTAssertEqual(f.runtime.displayTranslationText, firstTranslation)
        let steps = CaptionRollingBuffer.translationSteps(result, configuration: configuration)
        for index in 1..<steps.count {
            f.clock.now += 1.6
            f.feed(4, sid: sid, seq: index, bytes: Data([1]))
            f.runtime.tick()
            shown.append(try f.lensText())
        }
        for character in result { XCTAssertTrue(shown.contains { $0.contains(character) }) }
        XCTAssertTrue(f.runtime.displaySourceText.contains("current"))
        XCTAssertEqual(f.writer.entries.filter { $0.kind == .translation }.map(\.text), [result])
        XCTAssertTrue(shown.allSatisfy { $0.components(separatedBy: "\n").count == 5 && $0.utf8.count <= 384 })
    }

    @MainActor func testCloudProvidersReceiveOnlyMatchingNativeCaptionAudioAndPersistFinal() async throws {
        for service in CaptionService.allCases.filter({ $0.requiresCredential }) {
            let f = fixture(service)
            await f.runtime.start()?.value
            XCTAssertEqual(try f.types(), [1]); XCTAssertEqual(f.provider.starts, 0)
            let sid = try f.sid()
            f.feed(4, sid: sid, seq: 1, bytes: Data([1])) // No audio before accepted start.
            XCTAssertTrue(f.provider.audio.isEmpty)
            f.feed(2, sid: sid, code: 1)
            XCTAssertEqual(try f.types(), [1,7]); XCTAssertEqual(f.provider.starts, 1)
            f.feed(8, sid: sid, code: 1)
            f.feed(4, sid: "old", seq: 1, bytes: Data([1]))
            f.feed(4, sid: sid, seq: 1, bytes: Data([1]))
            f.feed(4, sid: sid, seq: 1, bytes: Data([1])) // Duplicate cannot duplicate PCM.
            XCTAssertEqual(f.provider.audio, [Data(repeating: 1, count: 640)])
            XCTAssertEqual(f.writer.pcmBytes, 640); XCTAssertEqual(f.runtime.packets, 1)
            f.provider.onText?("hello", false)
            f.provider.onText?("hello world", true)
            f.clock.now += 1; f.runtime.tick()
            XCTAssertEqual(f.runtime.recent.map(\.text), ["hello world"])
            let last = try XCTUnwrap(f.device.sent.last)
            let j = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(BusinessEnvelopeMetadata.messageJSON(last))) as? [String: Any])
            XCTAssertEqual((j["content"] as? [String: String])?["source_transcript"], "hello world")
            let late = f.provider.onText
            f.runtime.stop(); f.feed(4, sid: sid, seq: 2, bytes: Data([2])); late?("stale", true)
            XCTAssertEqual(f.runtime.packets, 1); XCTAssertEqual(f.runtime.recent.count, 1)
            XCTAssertEqual(f.writer.finished?.finalSentences, 1)
            XCTAssertEqual(f.writer.finished?.receivedPCMBytes, 640)
            XCTAssertFalse(f.device.subtitleOwnsDisplay)
            XCTAssertEqual(try f.types().last, 3)
            XCTAssertEqual(f.runtime.phase, .idle)
        }
    }
    @MainActor func testRejectedAndMissingStartCannotStartCloudOrLeaveUploadRunning() async throws {
        for timeout in [true, false] {
            let f = fixture()
            await f.runtime.start()?.value
            if timeout { f.clock.now += 11; f.runtime.tick() }
            else { f.feed(2, sid: try f.sid(), code: 9) }
            XCTAssertEqual(f.provider.starts, 0); XCTAssertNotNil(f.runtime.error)
            XCTAssertEqual(f.writer.finished?.state, .interrupted)
            XCTAssertEqual(f.runtime.phase, .idle)
            XCTAssertFalse(f.device.subtitleOwnsDisplay)
        }
    }
    @MainActor func testLateACKBeforeTimerFiresIsRejected() async throws {
        let f = fixture(); await f.runtime.start()?.value
        f.clock.now += 11
        f.feed(2, sid: try f.sid(), code: 1)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertFalse(f.device.subtitleOwnsDisplay)
    }
    @MainActor func testShortcutPersistsAndSecondTypeOneStopsUsingCurrentSID() async throws {
        let f = fixture()
        f.feed(1, sid: "glasses-shortcut")
        XCTAssertTrue(f.device.sent.isEmpty)
        f.runtime.setShortcut(true)
        let started = expectation(description: "shortcut accepts")
        f.runtime.onShortcutStart = { started.fulfill() }
        f.feed(1, sid: "glasses-shortcut")
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(try f.types(), [2,7])
        XCTAssertEqual(try f.sid(), "glasses-shortcut")
        XCTAssertTrue(f.runtime.controlEvents.contains { $0.contains("type=1 sid=current state=received") })
        XCTAssertEqual(f.provider.starts, 1)
        f.feed(1, sid: "duplicate-start") // Same physical tap duplicate is inside debounce.
        XCTAssertEqual(f.runtime.phase, .openingDisplay)
        f.clock.now += 2
        f.runtime.receive(device: "glasses", packet: try packet(1, sid: "delayed-old-duplicate"), arrival: 100.5)
        XCTAssertEqual(f.runtime.phase, .openingDisplay)
        f.feed(1, sid: "second-double-tap-new-sid")
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertFalse(f.device.subtitleOwnsDisplay)
        XCTAssertEqual(f.writer.finished?.state, .completed)
        XCTAssertEqual(try f.types(), [2,7,3])
        XCTAssertEqual(try SubtitleTranslateWire.event(f.device.sent.last!).sid, "glasses-shortcut")
        let fresh = SubtitleRealtimeRuntime(voice: f.device, settings: f.settings, archive: f.archive, defaults: f.defaults, scheduleTimers: false)
        XCTAssertTrue(fresh.shortcutEnabled)
        fresh.setShortcut(false)
        let disabled = SubtitleRealtimeRuntime(voice: f.device, settings: f.settings, archive: f.archive, defaults: f.defaults, scheduleTimers: false)
        XCTAssertFalse(disabled.shortcutEnabled)
    }
    @MainActor func testCrashMarkerNeverBlocksRestartOrRequiresManualExitConfirmation() {
        let f = fixture()
        f.defaults.set(true, forKey: "companion.realtimeSubtitles.exitPending.v1")
        let fresh = SubtitleRealtimeRuntime(voice: f.device, settings: f.settings, archive: f.archive, defaults: f.defaults, scheduleTimers: false)
        XCTAssertEqual(fresh.phase, .idle)
        XCTAssertTrue(fresh.canStart)
        XCTAssertFalse(f.defaults.bool(forKey: "companion.realtimeSubtitles.exitPending.v1"))
        XCTAssertTrue(fresh.status.contains("自动清理"))
    }
    @MainActor func testGlassesStartDuringSaveAndCooldownIsNotQueued() async throws {
        let f = fixture(); f.writer.deferFinish = true; f.runtime.setShortcut(true)
        let firstStarted = expectation(description: "first shortcut starts")
        f.runtime.onShortcutStart = { firstStarted.fulfill() }
        f.feed(1, sid: "first-shortcut")
        await fulfillment(of: [firstStarted], timeout: 3)
        f.clock.now += 2
        f.feed(1, sid: "stop-shortcut")
        XCTAssertEqual(f.runtime.phase, .idle); XCTAssertTrue(f.runtime.saving)
        f.feed(1, sid: "second-shortcut")
        XCTAssertTrue(f.runtime.status.contains("保存") || f.runtime.status.contains("防抖"))
        f.writer.complete()
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(try f.types(), [2,7,3])
        f.clock.now += 2
        let secondStarted = expectation(description: "fresh shortcut starts after explicit later tap")
        f.runtime.onShortcutStart = { secondStarted.fulfill() }
        f.feed(1, sid: "fresh-shortcut")
        await fulfillment(of: [secondStarted], timeout: 3)
        XCTAssertEqual(f.runtime.phase, .openingDisplay)
        XCTAssertEqual(try f.types(), [2,7,3,2,7])
        f.writer.deferFinish = false
    }
    @MainActor func testMatchingTypeThreeStopsWithoutEchoAndTailTypeOneWaitsForCooldown() async throws {
        let f = fixture(); f.runtime.setShortcut(true)
        let firstStarted = expectation(description: "first shortcut starts")
        f.runtime.onShortcutStart = { firstStarted.fulfill() }
        f.feed(1, sid: "first-shortcut")
        await fulfillment(of: [firstStarted], timeout: 3)
        let activeSID = try f.sid()
        f.clock.now += 2
        f.feed(3, sid: activeSID)
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(try f.types(), [2, 7])

        let tailArrival = f.clock.now + 0.2
        f.clock.now += 2
        f.runtime.receive(device: "glasses", packet: try packet(1, sid: "tail-after-stop"), arrival: tailArrival)
        XCTAssertEqual(f.runtime.phase, .idle)
        XCTAssertEqual(try f.types(), [2, 7])
        let nextStarted = expectation(description: "new shortcut after cooldown starts")
        f.runtime.onShortcutStart = { nextStarted.fulfill() }
        f.feed(1, sid: "new-deliberate-shortcut")
        await fulfillment(of: [nextStarted], timeout: 3)
        XCTAssertEqual(f.runtime.phase, .openingDisplay)
        XCTAssertEqual(try f.types(), [2, 7, 2, 7])
    }
    @MainActor func testLatencyExperimentReceivesRealRuntimeBoundaries() async throws {
        let f = fixture(); f.runtime.latency.setEnabled(true)
        await f.runtime.start()?.value
        let sid = try f.sid()
        f.clock.now += 0.1; f.feed(2, sid: sid, code: 1)
        f.clock.now += 0.1; f.feed(8, sid: sid, code: 1)
        f.clock.now += 0.2; f.feed(4, sid: sid, seq: 10, bytes: Data([1]))
        f.clock.now += 0.4; f.provider.onText?("timing fixture", false)

        XCTAssertEqual(f.runtime.latency.snapshot(.handshakeToFirstAudio).last, 300)
        XCTAssertEqual(f.runtime.latency.snapshot(.firstAudioToFirstResult).last, 400)
        XCTAssertEqual(f.runtime.latency.snapshot(.resultToGlassesSubmit).last, 0)
        XCTAssertTrue(f.runtime.latency.report.contains("Deepgram"))
        f.runtime.stop()
    }
    @MainActor func testNonUnitSequenceStrideDoesNotSplitRecordingAndDuplicatesAreDropped() async throws {
        let f = fixture(); await f.runtime.start()?.value
        let sid = try f.sid(); f.feed(2,sid:sid,code:1); f.feed(8,sid:sid,code:2)
        for index in 0..<600 { f.feed(4,sid:sid,seq:index * 10,bytes:Data([1])) }
        f.feed(4,sid:sid,seq:5_990,bytes:Data([2]))
        f.feed(4,sid:sid,seq:5_980,bytes:Data([3]))
        XCTAssertEqual(f.runtime.packets, 600); XCTAssertEqual(f.runtime.gaps, 0)
        XCTAssertEqual(f.runtime.sequenceJumps, 599); XCTAssertEqual(f.runtime.maximumSequenceStep, 10)
        XCTAssertEqual(f.runtime.discardedSequencePackets, 2)
        XCTAssertEqual(f.decoder.resets, 0); XCTAssertEqual(f.writer.gaps, 0)
        XCTAssertTrue(f.runtime.diagnosticText.contains("seqStrideChanges=599"))
        XCTAssertTrue(f.runtime.diagnosticText.contains("seqSteps=10:599"))
        f.runtime.stop(); XCTAssertEqual(f.writer.finished?.state, .completed); XCTAssertEqual(f.runtime.phase, .idle)
    }
    @MainActor func testConfirmedQueueAndArrivalLossSplitOnceAndStalePacketsAreDropped() async throws {
        let f = fixture(); await f.runtime.start()?.value
        let sid = try f.sid(); f.feed(2,sid:sid,code:1); f.feed(8,sid:sid,code:2)
        f.clock.now += 1 // Startup latency before the first packet is not a recording gap.
        f.feed(4,sid:sid,seq:100,bytes:Data([1]))
        f.runtime.inputLost(); f.runtime.inputLost()
        f.feed(4,sid:sid,seq:120,bytes:Data([2]))
        f.clock.now += 1
        f.feed(4,sid:sid,seq:140,bytes:Data([3]))
        f.runtime.receive(device: "glasses", packet: try packet(4,sid:sid,seq:160,bytes:Data([4])), arrival: f.clock.now - 1)
        XCTAssertEqual(f.runtime.packets, 3); XCTAssertEqual(f.runtime.gaps, 2)
        XCTAssertEqual(f.runtime.discardedSequencePackets, 1)
        XCTAssertEqual(f.decoder.resets, 2); XCTAssertEqual(f.writer.gaps, 2)
        f.runtime.stop(); XCTAssertEqual(f.writer.finished?.state, .interrupted); XCTAssertEqual(f.runtime.phase, .idle)
    }
    @MainActor func testMainQueueDelayKeepsChronologicalAudioAndDuplicateEndStillStops() async throws {
        let f = fixture(); await f.runtime.start()?.value
        let sid = try f.sid(); f.feed(2,sid:sid,code:1); f.feed(8,sid:sid,code:2)
        f.feed(4,sid:sid,seq:100,bytes:Data([1]))
        f.clock.now += 2
        f.runtime.receive(device: "glasses", packet: try packet(4,sid:sid,seq:120,bytes:Data([2])), arrival: f.clock.now - 1.9)
        XCTAssertEqual(f.runtime.packets, 2); XCTAssertEqual(f.runtime.gaps, 0)
        XCTAssertGreaterThanOrEqual(f.runtime.maximumDispatchDelayMilliseconds, 1_800)
        XCTAssertLessThan(f.runtime.maximumArrivalIntervalMilliseconds, 750)
        let end = try DeviceBusinessWire.encode(type: 4, json: ["sid":sid,"seq":120,"end":true])
        f.runtime.receive(device: "glasses", packet: end, arrival: f.clock.now - 1.8)
        XCTAssertEqual(f.runtime.phase, .idle); XCTAssertEqual(f.writer.finished?.state, .completed)
        XCTAssertFalse(f.device.subtitleOwnsDisplay)
    }
    @MainActor func testDisconnectStopsCloudAndNeverSendsCleanupToReplacement() async throws {
        let f = fixture(); await f.runtime.start()?.value
        f.feed(2,sid:try f.sid(),code:1)
        let sent = f.device.sent.count
        f.device.deviceID = "replacement"; f.runtime.connectionChanged()
        XCTAssertEqual(f.runtime.phase, .idle); XCTAssertEqual(f.provider.stops, 1)
        XCTAssertEqual(f.device.sent.count, sent); XCTAssertEqual(f.writer.finished?.state, .interrupted)
        XCTAssertFalse(f.device.subtitleOwnsDisplay)
    }
    @MainActor func testCancelPreparationAndStorageFailureNeverStartMicrophone() async throws {
        let f = fixture()
        let task = f.runtime.start()
        f.runtime.stop(); await task?.value
        XCTAssertTrue(f.device.sent.isEmpty); XCTAssertEqual(f.runtime.phase, .idle)
        let broken = SubtitleRealtimeRuntime(voice:f.device,settings:f.settings,archive:f.archive,defaults:f.defaults,
            makeDecoder:{ f.decoder },makeWriter:{ _,_,_ in throw CaptionFailure.limit },scheduleTimers:false)
        await broken.start()?.value
        XCTAssertEqual(broken.phase,.idle); XCTAssertNotNil(broken.error)
        XCTAssertFalse(f.device.subtitleOwnsDisplay)
    }
    @MainActor func testSavingConfigurationNeverStartsAndKeysAreProviderScoped() throws {
        let f = fixture(.azure)
        XCTAssertTrue(f.device.sent.isEmpty); XCTAssertEqual(f.provider.starts,0)
        var changed = f.settings.options; changed.service = .deepgram
        XCTAssertTrue(f.settings.save(changed)); XCTAssertFalse(f.settings.hasKey)
        f.settings.isBusy = { true }
        XCTAssertFalse(f.settings.save(changed,key:"synthetic-second-key"))
    }
    @MainActor func testPickupDirectionUsesAheadAtStartAndCurrentSIDForLiveSwitch() async throws {
        let f = fixture()
        f.runtime.setPickupDirection(.ahead)
        XCTAssertEqual(f.settings.pickupDirection, .ahead)
        await f.runtime.start()?.value
        let sid = try f.sid()
        let startJSON = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(BusinessEnvelopeMetadata.messageJSON(XCTUnwrap(f.device.sent.first)))) as? [String: Any])
        XCTAssertEqual((startJSON["settings"] as? [String: Any])?["direction"] as? String, "ahead")

        f.feed(2, sid: sid, code: 1); f.feed(8, sid: sid, code: 1)
        XCTAssertEqual(f.runtime.phase, .listening)
        f.runtime.setPickupDirection(.around)
        XCTAssertEqual(try f.types(), [1, 7, 10])
        let sync = try XCTUnwrap(f.device.sent.last)
        let syncJSON = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(BusinessEnvelopeMetadata.messageJSON(sync))) as? [String: Any])
        XCTAssertEqual(syncJSON["sid"] as? String, sid)
        XCTAssertEqual((syncJSON["settings"] as? [String: Any])?["direction"] as? String, "around")
        XCTAssertFalse(f.runtime.diagnosticText.contains(sid))
        XCTAssertTrue(f.runtime.diagnosticText.contains("sid=current"))
        f.feed(10, sid: sid, code: 2) // Observe a possible type-10 response without assuming it is an apply ACK.
        XCTAssertTrue(f.runtime.controlEvents.contains { $0.contains("type=10 sid=current") && $0.contains("code=2") })
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.runtime.phase, .listening)
        f.feed(4, sid: sid, seq: 1, bytes: Data([1]))
        XCTAssertEqual(f.runtime.packets, 1)

        f.runtime.setPickupDirection(.ahead)
        XCTAssertEqual(try f.types(), [1, 7, 10, 10])
        XCTAssertEqual(f.settings.pickupDirection, .ahead)
        let provider = f.provider
        let reloaded = SubtitleSettingsStore(defaults: f.defaults, credentials: f.vault,
                                             allowsChanges: true, factory: { _ in provider })
        XCTAssertEqual(reloaded.pickupDirection, .ahead)
    }
    @MainActor func testPickupDirectionDiagnosticsAreScopedToOneSessionAndSurviveStop() async throws {
        let f = fixture()
        await f.runtime.start()?.value
        let sid = try f.sid()
        f.feed(2, sid: sid, code: 1); f.feed(8, sid: sid, code: 1)
        f.runtime.setPickupDirection(.ahead)
        f.runtime.stop()
        XCTAssertTrue(f.runtime.diagnosticText.contains("type=10 direction=ahead state=submitted"))

        f.clock.now += 2
        await f.runtime.start()?.value
        XCTAssertEqual(f.runtime.phase, .startingAudio)
        XCTAssertEqual(f.runtime.controlEvents.filter { $0.contains("type=1 direction=ahead state=submitted") }.count, 1)
        XCTAssertFalse(f.runtime.controlEvents.contains { $0.contains("type=10") })
    }
    @MainActor func testPickupDirectionUsesAheadForGlassesStartAndDoesNotStopOnSwitchFailure() async throws {
        let f = fixture()
        f.runtime.setShortcut(true)
        f.runtime.setPickupDirection(.ahead)
        let started = expectation(description: "glasses subtitle start")
        f.runtime.onShortcutStart = { started.fulfill() }
        f.feed(1, sid: "glasses-direction")
        await fulfillment(of: [started], timeout: 3)
        let result = try XCTUnwrap(f.device.sent.first)
        let resultJSON = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(BusinessEnvelopeMetadata.messageJSON(result))) as? [String: Any])
        XCTAssertEqual((resultJSON["final_settings"] as? [String: Any])?["direction"] as? String, "ahead")
        f.runtime.setPickupDirection(.around) // Wait for the display handshake before changing the live session.
        XCTAssertEqual(f.settings.pickupDirection, .ahead)
        XCTAssertEqual(try f.types(), [2, 7])
        f.feed(8, sid: "glasses-direction", code: 1)

        f.device.failType10 = true
        f.runtime.setPickupDirection(.around)
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertEqual(f.settings.pickupDirection, .ahead)
        XCTAssertEqual(try f.types(), [2, 7])
        XCTAssertNotNil(f.runtime.error)
        XCTAssertTrue(f.runtime.pickupDirectionNeedsRetry)
        XCTAssertTrue(f.runtime.controlEvents.contains { $0.contains("type=10 direction=around state=submit_failed packets=0 gaps=0") })

        f.device.failType10 = false
        f.runtime.retryPickupDirection()
        let submitted = try XCTUnwrap(f.device.sent.last)
        XCTAssertEqual(try BusinessEnvelopeMetadata.inspect(submitted).messageType, 10)
        f.runtime.transportFailed(device: "glasses", packet: submitted, code: 42,
                                  messageID: try XCTUnwrap(f.device.sentMessageIDs.last))
        XCTAssertEqual(f.runtime.phase, .listening)
        XCTAssertEqual(f.provider.stops, 0)
        XCTAssertTrue(f.runtime.controlEvents.contains { $0.contains("type=10 direction=around state=send_failed code=42") })
        f.runtime.retryPickupDirection()
        XCTAssertEqual(try f.types(), [2, 7, 10, 10])
    }
    @MainActor func testLateIdenticalDirectionFailureDoesNotMarkLatestSwitchFailed() async throws {
        let f = fixture()
        await f.runtime.start()?.value
        let sid = try f.sid()
        f.feed(2, sid: sid, code: 1); f.feed(8, sid: sid, code: 1)

        f.runtime.setPickupDirection(.ahead)
        let firstPacket = try XCTUnwrap(f.device.sent.last)
        let firstID = try XCTUnwrap(f.device.sentMessageIDs.last)
        f.runtime.setPickupDirection(.around)
        f.runtime.setPickupDirection(.ahead)
        let latestPacket = try XCTUnwrap(f.device.sent.last)
        let latestID = try XCTUnwrap(f.device.sentMessageIDs.last)
        XCTAssertEqual(firstPacket, latestPacket)
        XCTAssertNotEqual(firstID, latestID)

        f.runtime.transportFailed(device: "glasses", packet: firstPacket, code: 42,
                                  messageID: firstID)
        XCTAssertTrue(f.runtime.controlEvents.contains { $0.contains("type=10 direction=ahead state=stale_send_failed code=42") })
        XCTAssertFalse(f.runtime.pickupDirectionNeedsRetry)
        XCTAssertNil(f.runtime.error)
        XCTAssertEqual(f.runtime.phase, .listening)

        f.runtime.transportFailed(device: "glasses", packet: latestPacket, code: 42,
                                  messageID: latestID)
        XCTAssertTrue(f.runtime.pickupDirectionNeedsRetry)
        f.runtime.retryPickupDirection()
        let retryID = try XCTUnwrap(f.device.sentMessageIDs.last)
        XCTAssertNotEqual(retryID, latestID)
        XCTAssertFalse(f.runtime.pickupDirectionNeedsRetry)
        f.runtime.transportFailed(device: "glasses", packet: latestPacket, code: 43,
                                  messageID: latestID)
        XCTAssertFalse(f.runtime.pickupDirectionNeedsRetry)
        XCTAssertNil(f.runtime.error)

        f.device.failType10 = true
        f.runtime.setPickupDirection(.around)
        let synchronousError = f.runtime.error
        XCTAssertNotNil(synchronousError)
        f.runtime.transportFailed(device: "glasses", packet: latestPacket, code: 44,
                                  messageID: retryID)
        XCTAssertTrue(f.runtime.pickupDirectionNeedsRetry)
        XCTAssertEqual(f.runtime.error, synchronousError)
    }
    private func packet(_ type:UInt32,sid:String,code:Int?=nil,seq:Int?=nil,bytes:Data=Data()) throws -> Data {
        var j:[String:Any] = ["sid":sid]; if let code {j["code"]=code}; if let seq {j["seq"]=seq}
        return try DeviceBusinessWire.encode(type:type,json:j,bytes:bytes)
    }
    @MainActor private func fixture(_ service:CaptionService = .deepgram) -> Fixture {
        let f=Fixture(service)
        addTeardownBlock { await self.cleanup(f) }; return f
    }
    @MainActor private func cleanup(_ f:Fixture) {
        f.runtime.stop(); f.defaults.removePersistentDomain(forName:f.name)
    }
    @MainActor private final class Fixture {
        let name="subtitle-rt-tests-"+UUID().uuidString
        let defaults:UserDefaults,settings:SubtitleSettingsStore,archive:SubtitleArchiveStore
        let device=Device(),provider=Provider(),decoder=Decoder(),writer=Writer(),clock=Clock(),vault=Vault()
        let runtime:SubtitleRealtimeRuntime
        init(_ service:CaptionService, rolling: Bool = false, translator: Translator? = nil) {
            defaults=UserDefaults(suiteName:name)!
            let provider=provider
            settings=SubtitleSettingsStore(defaults:defaults,credentials:vault,allowsChanges:true,factory:{_ in provider})
            var options=CaptionOptions();options.service=service;options.region="eastus";options.aliyunHost="workspace-a.cn-beijing.maas.aliyuncs.com";options.recordAudio=true
            options.selfHostedEndpoint="wss://asr.example.com/compat/openai/v1/realtime"
            XCTAssertTrue(settings.save(options,key:"synthetic-test-only"))
            XCTAssertTrue(settings.saveDisplayPreferences(mode: .bilingual, order: .sourceFirst,
                retention: .untilNextSentence, displayLayout: rolling ? .rolling : .sentence))
            if translator != nil { settings.saveTranslationEnabled(true) }
            archive=SubtitleArchiveStore(root:FileManager.default.temporaryDirectory.appendingPathComponent(name))
            let decoder=decoder,writer=writer,clock=clock
            runtime=SubtitleRealtimeRuntime(voice:device,settings:settings,archive:archive,defaults:defaults,
                makeDecoder:{decoder},makeWriter:{_,_,_ in writer},uptime:{clock.now},scheduleTimers:false,
                makeTranslator: translator.map { client in { _, _, _ in client } })
        }
        func types() throws -> [UInt32] {try device.sent.map{try XCTUnwrap(BusinessEnvelopeMetadata.inspect($0).messageType)}}
        func sid() throws -> String {try SubtitleTranslateWire.event(XCTUnwrap(device.sent.first)).sid}
        func lensText() throws -> String {
            let packet = try XCTUnwrap(device.sent.last { (try? BusinessEnvelopeMetadata.inspect($0))?.messageType == 5 })
            let json = try XCTUnwrap(BusinessEnvelopeMetadata.messageJSON(packet))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            return try XCTUnwrap((body["content"] as? [String: String])?["source_transcript"])
        }
        func feed(_ type:UInt32,sid:String,code:Int?=nil,seq:Int?=nil,bytes:Data=Data()) {
            var j:[String:Any]=["sid":sid];if let code {j["code"]=code};if let seq {j["seq"]=seq}
            runtime.receive(device:"glasses",packet:try! DeviceBusinessWire.encode(type:type,json:j,bytes:bytes),arrival:clock.now)
        }
    }
    private final class Clock {var now:TimeInterval=100}
    private final class Decoder:SubtitlePCMDecoder {
        var resets=0
        func decode(_ packet:Data)->Data? {Data(repeating:1,count:640)}
        func reset(){resets+=1}
    }
    private final class Writer:SubtitleSessionWriting {
        var entries:[CaptionEntry]=[],pcmBytes=0,gaps=0,deferFinish=false
        var finished:SubtitleSessionRecord?
        var finishCompletion:((Bool)->Void)?
        var onTranslation: (() -> Void)?
        func event(_ entry:CaptionEntry){entries.append(entry);if entry.kind == .translation {onTranslation?()}}
        func pcm(_ data:Data){pcmBytes+=data.count}
        func gap(){gaps+=1}
        func finish(_ record:SubtitleSessionRecord,completion:@escaping(Bool)->Void){
            finished=record
            if deferFinish { finishCompletion=completion } else { completion(true) }
        }
        func complete(){let completion=finishCompletion;finishCompletion=nil;completion?(true)}
    }
    @MainActor private final class Translator: SubtitleTranslationClient {
        var onRequest: (() -> Void)?
        private var continuation: CheckedContinuation<String, Error>?
        func translate(_ text: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                onRequest?()
            }
        }
        func complete(_ text: String) { continuation?.resume(returning: text); continuation = nil }
        func cancel() { continuation?.resume(throwing: CancellationError()); continuation = nil }
    }
    private final class Vault:SubtitleCredentialStorage {
        var keys:[String:String]=[:]
        func key(for options:CaptionOptions)->String?{keys[options.credentialService+options.credentialAccount]}
        func save(_ key:String,for options:CaptionOptions)throws{keys[options.credentialService+options.credentialAccount]=key}
        func remove(for options:CaptionOptions)throws{keys.removeValue(forKey:options.credentialService+options.credentialAccount)}
    }
    @MainActor private final class Provider:CaptionASRProvider {
        var onText:((String,Bool)->Void)?,onEndpoint:(()->Void)?,onReady:(()->Void)?,onFailure:((CaptionConnectionFailure)->Void)?
        var starts=0,stops=0,audio:[Data]=[]
        func start(options:CaptionOptions,key:String){starts+=1;onReady?()}
        func append(_ pcm:Data){audio.append(pcm)}
        func stop(){stops+=1}
    }
    @MainActor private final class Device:SubtitleRealtimeDevice {
        var supportsDevice=true,deviceID:String?="glasses",subtitleOwnsDisplay=false
        var featureIsBusy:(()->Bool)?
        var sent:[Data]=[], sentMessageIDs:[String]=[]
        var failType10=false
        func prepare(){}
        func ownDisplayForSubtitles(_ owns:Bool){subtitleOwnsDisplay=owns}
        @discardableResult func sendRealtimeSubtitle(target:String,payload:Data)throws -> String {
            XCTAssertTrue(subtitleOwnsDisplay);XCTAssertEqual(target,deviceID)
            if failType10 {
                let metadata = try BusinessEnvelopeMetadata.inspect(payload)
                if metadata.messageType == 10 {
                    throw NSError(domain: "SyntheticDirectionSendFailure", code: 1)
                }
            }
            try SubtitleTranslateWire.validateOutbound(payload)
            let messageID = UUID().uuidString
            sent.append(payload);sentMessageIDs.append(messageID)
            return messageID
        }
    }
}
