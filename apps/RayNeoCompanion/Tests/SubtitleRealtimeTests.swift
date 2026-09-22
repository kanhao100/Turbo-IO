import XCTest
import RayNeoProtocol
import RayNeoCaptions
@testable import RayNeoCompanion

final class SubtitleRealtimeTests: XCTestCase {
    @MainActor func testFourProvidersReceiveOnlyMatchingNativeCaptionAudioAndPersistFinal() async throws {
        for service in CaptionService.allCases {
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
        XCTAssertEqual(f.provider.starts, 1)
        f.feed(1, sid: "duplicate-start") // Same physical tap duplicate is inside debounce.
        XCTAssertEqual(f.runtime.phase, .openingDisplay)
        f.clock.now += 2
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
        init(_ service:CaptionService) {
            defaults=UserDefaults(suiteName:name)!
            let provider=provider
            settings=SubtitleSettingsStore(defaults:defaults,credentials:vault,allowsChanges:true,factory:{_ in provider})
            var options=CaptionOptions();options.service=service;options.region="eastus";options.aliyunHost="workspace-a.cn-beijing.maas.aliyuncs.com";options.recordAudio=true
            options.selfHostedEndpoint="wss://asr.example.com/compat/openai/v1/realtime"
            XCTAssertTrue(settings.save(options,key:"synthetic-test-only"))
            archive=SubtitleArchiveStore(root:FileManager.default.temporaryDirectory.appendingPathComponent(name))
            let decoder=decoder,writer=writer,clock=clock
            runtime=SubtitleRealtimeRuntime(voice:device,settings:settings,archive:archive,defaults:defaults,
                makeDecoder:{decoder},makeWriter:{_,_,_ in writer},uptime:{clock.now},scheduleTimers:false)
        }
        func types() throws -> [UInt32] {try device.sent.map{try XCTUnwrap(BusinessEnvelopeMetadata.inspect($0).messageType)}}
        func sid() throws -> String {try SubtitleTranslateWire.event(XCTUnwrap(device.sent.first)).sid}
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
        func event(_ entry:CaptionEntry){entries.append(entry)}
        func pcm(_ data:Data){pcmBytes+=data.count}
        func gap(){gaps+=1}
        func finish(_ record:SubtitleSessionRecord,completion:@escaping(Bool)->Void){
            finished=record
            if deferFinish { finishCompletion=completion } else { completion(true) }
        }
        func complete(){let completion=finishCompletion;finishCompletion=nil;completion?(true)}
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
        var sent:[Data]=[]
        func prepare(){}
        func ownDisplayForSubtitles(_ owns:Bool){subtitleOwnsDisplay=owns}
        func sendRealtimeSubtitle(target:String,payload:Data)throws {
            XCTAssertTrue(subtitleOwnsDisplay);XCTAssertEqual(target,deviceID)
            try SubtitleTranslateWire.validateOutbound(payload);sent.append(payload)
        }
    }
}
