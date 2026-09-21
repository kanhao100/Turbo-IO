import XCTest
import RayNeoProtocol
import RayNeoCaptions
@testable import RayNeoCompanion

final class SubtitleRealtimeTests: XCTestCase {
    @MainActor func testFourProvidersReceiveOnlyMatchingNativeCaptionAudioAndPersistFinal() async throws {
        for service in CaptionService.allCases {
            let f = fixture(service)
            await f.runtime.start(consented: true)?.value
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
            XCTAssertTrue(f.device.subtitleOwnsDisplay)
            XCTAssertEqual(try f.types().last, 3)
            f.runtime.confirmExited(); XCTAssertFalse(f.device.subtitleOwnsDisplay)
        }
    }
    @MainActor func testRejectedAndMissingStartCannotStartCloudOrLeaveUploadRunning() async throws {
        for timeout in [true, false] {
            let f = fixture()
            await f.runtime.start(consented: true)?.value
            if timeout { f.clock.now += 11; f.runtime.tick() }
            else { f.feed(2, sid: try f.sid(), code: 9) }
            XCTAssertEqual(f.provider.starts, 0); XCTAssertNotNil(f.runtime.error)
            XCTAssertEqual(f.writer.finished?.state, .interrupted)
            f.clock.now += 9; f.runtime.tick(); XCTAssertEqual(f.runtime.phase, .uncertain)
            f.runtime.confirmExited()
        }
    }
    @MainActor func testLateACKBeforeTimerFiresIsRejected() async throws {
        let f = fixture(); await f.runtime.start(consented: true)?.value
        f.clock.now += 11
        f.feed(2, sid: try f.sid(), code: 1)
        XCTAssertEqual(f.provider.starts, 0)
        XCTAssertEqual(f.runtime.phase, .stopping)
        f.runtime.confirmExited()
    }
    @MainActor func testShortcutRequiresOptInAndUsesIncomingSIDWithoutAIWake() async throws {
        let f = fixture()
        f.feed(1, sid: "glasses-shortcut")
        XCTAssertTrue(f.device.sent.isEmpty)
        f.runtime.setShortcut(true, consented: true)
        f.feed(1, sid: "glasses-shortcut")
        let started = expectation(description: "shortcut accepts")
        f.runtime.onShortcutStart = { started.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(try f.types(), [2,7])
        XCTAssertEqual(try f.sid(), "glasses-shortcut")
        XCTAssertEqual(f.provider.starts, 1)
        f.runtime.stop(); f.runtime.confirmExited()
        let fresh = SubtitleRealtimeRuntime(voice: f.device, settings: f.settings, archive: f.archive, defaults: f.defaults, scheduleTimers: false)
        XCTAssertFalse(fresh.shortcutEnabled)
    }
    @MainActor func testNonUnitSequenceStrideDoesNotSplitRecordingAndDuplicatesAreDropped() async throws {
        let f = fixture(); await f.runtime.start(consented: true)?.value
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
        f.runtime.stop(); XCTAssertEqual(f.writer.finished?.state, .completed); f.runtime.confirmExited()
    }
    @MainActor func testConfirmedQueueAndArrivalLossSplitOnceAndStalePacketsAreDropped() async throws {
        let f = fixture(); await f.runtime.start(consented: true)?.value
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
        f.runtime.stop(); XCTAssertEqual(f.writer.finished?.state, .interrupted); f.runtime.confirmExited()
    }
    @MainActor func testMainQueueDelayKeepsChronologicalAudioAndDuplicateEndStillStops() async throws {
        let f = fixture(); await f.runtime.start(consented: true)?.value
        let sid = try f.sid(); f.feed(2,sid:sid,code:1); f.feed(8,sid:sid,code:2)
        f.feed(4,sid:sid,seq:100,bytes:Data([1]))
        f.clock.now += 2
        f.runtime.receive(device: "glasses", packet: try packet(4,sid:sid,seq:120,bytes:Data([2])), arrival: f.clock.now - 1.9)
        XCTAssertEqual(f.runtime.packets, 2); XCTAssertEqual(f.runtime.gaps, 0)
        XCTAssertGreaterThanOrEqual(f.runtime.maximumDispatchDelayMilliseconds, 1_800)
        XCTAssertLessThan(f.runtime.maximumArrivalIntervalMilliseconds, 750)
        let end = try DeviceBusinessWire.encode(type: 4, json: ["sid":sid,"seq":120,"end":true])
        f.runtime.receive(device: "glasses", packet: end, arrival: f.clock.now - 1.8)
        XCTAssertEqual(f.runtime.phase, .stopping); XCTAssertEqual(f.writer.finished?.state, .completed)
        f.runtime.confirmExited()
    }
    @MainActor func testDisconnectStopsCloudAndNeverSendsCleanupToReplacement() async throws {
        let f = fixture(); await f.runtime.start(consented: true)?.value
        f.feed(2,sid:try f.sid(),code:1)
        let sent = f.device.sent.count
        f.device.deviceID = "replacement"; f.runtime.connectionChanged()
        XCTAssertEqual(f.runtime.phase, .uncertain); XCTAssertEqual(f.provider.stops, 1)
        XCTAssertEqual(f.device.sent.count, sent); XCTAssertEqual(f.writer.finished?.state, .interrupted)
        f.runtime.confirmExited()
    }
    @MainActor func testCancelPreparationAndStorageFailureNeverStartMicrophone() async throws {
        let f = fixture()
        let task = f.runtime.start(consented: true)
        f.runtime.stop(); await task?.value
        XCTAssertTrue(f.device.sent.isEmpty); XCTAssertEqual(f.runtime.phase, .idle)
        let broken = SubtitleRealtimeRuntime(voice:f.device,settings:f.settings,archive:f.archive,defaults:f.defaults,
            makeDecoder:{ f.decoder },makeWriter:{ _,_,_ in throw CaptionFailure.limit },scheduleTimers:false)
        await broken.start(consented:true)?.value
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
        f.runtime.stop(); f.runtime.confirmExited(); f.defaults.removePersistentDomain(forName:f.name)
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
            var options=CaptionOptions();options.service=service;options.region="eastus";options.aliyunHost="test.aliyuncs.com";options.recordAudio=true
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
        var entries:[CaptionEntry]=[],pcmBytes=0,gaps=0
        var finished:SubtitleSessionRecord?
        func event(_ entry:CaptionEntry){entries.append(entry)}
        func pcm(_ data:Data){pcmBytes+=data.count}
        func gap(){gaps+=1}
        func finish(_ record:SubtitleSessionRecord,completion:@escaping(Bool)->Void){finished=record;completion(true)}
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
