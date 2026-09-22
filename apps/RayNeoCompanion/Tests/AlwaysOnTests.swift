import XCTest
import RayNeoProtocol
import RayNeoCaptions
@testable import RayNeoCompanion

@MainActor final class AlwaysOnTests: XCTestCase {
    func testWireRequiresExactTaskFrameCountAndSize() throws {
        for command in ["life_log_guide", "life_log_switch"] {
            let wire = try DeviceBusinessWire(AlwaysOnWire.launcher(command, enabled: true))
            XCTAssertEqual(wire.type, 20)
            XCTAssertEqual(wire.json["cmd"] as? String, command)
        }
        let valid = try DeviceBusinessWire(DeviceBusinessWire.encode(type: 163,
            json: ["taskId": "task", "frameCount": 2], bytes: Data(repeating: 1, count: 480)))
        XCTAssertEqual(try AlwaysOnWire.frames(valid, taskID: "task").map(\.count), [240, 240])
        for (json, bytes): ([String: Any], Data) in [
            (["taskId": "other", "frameCount": 1], Data(repeating: 1, count: 240)),
            (["taskId": "task"], Data(repeating: 1, count: 240)),
            (["taskId": "task", "frameCount": 32], Data(repeating: 1, count: 7_680)),
            (["taskId": "task", "frameCount": 2], Data(repeating: 1, count: 240))
        ] {
            let wire = try DeviceBusinessWire(DeviceBusinessWire.encode(type: 163, json: json, bytes: bytes))
            XCTAssertThrowsError(try AlwaysOnWire.frames(wire, taskID: "task"))
        }
    }

    func testPersistentEnableA1A2RealtimePCMFinalTextAndNoAudioFiles() async throws {
        let f = fixture()
        f.runtime.setEnabled(true)
        XCTAssertTrue(f.runtime.enabled); XCTAssertEqual(try f.businessTypes(15), [20, 20])
        f.feed(13, type: 161)
        XCTAssertEqual(try f.businessTypes(13), [162, 168])
        let page = try XCTUnwrap(f.businessPackets.first { $0.0 == 13 && (try? DeviceBusinessWire($0.1).type) == 168 })
        XCTAssertEqual(DeviceBusinessWire.boolean(try DeviceBusinessWire(page.1).json, "inRealtimePage"), true)
        let task = try f.taskID()
        f.feed(13, type: 163, json: ["taskId": task, "frameCount": 2], bytes: Data(repeating: 7, count: 480))
        XCTAssertEqual(f.provider.audio.count, 2); XCTAssertEqual(f.runtime.packets, 1)
        f.provider.onText?("今天的第一句", false)
        f.provider.onText?("今天的第一句。", true)
        XCTAssertEqual(f.runtime.todaySentences, 1); XCTAssertEqual(f.runtime.partial, "")
        let entries = try await f.archive.entries(for: f.archive.dayKey(for: Date()))
        XCTAssertTrue(entries.contains { $0.kind == .final && $0.text == "今天的第一句。" })
        XCTAssertTrue(entries.allSatisfy { $0.service == CaptionService.aliyun.name })
        let enumerator = FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: nil)
        var forbidden: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".wav") || name.hasSuffix(".opus") || name.hasSuffix(".pcm") || name.hasSuffix(".rnp") { forbidden.append(name) }
        }
        XCTAssertTrue(forbidden.isEmpty)
        f.feed(13, type: 165)
        XCTAssertEqual(f.runtime.phase, .waitingForA1); XCTAssertTrue(f.runtime.enabled)
        f.runtime.setEnabled(false)
    }

    func testA4IsNeverUploadedAndProducesVisibleGap() throws {
        let f = fixture(); f.runtime.setEnabled(true); f.feed(13, type: 161)
        let task = try f.taskID()
        f.feed(13, type: 164, json: ["taskId": task, "frameCount": 2], bytes: Data(repeating: 9, count: 480))
        XCTAssertTrue(f.provider.audio.isEmpty)
        XCTAssertEqual(f.runtime.cachedPackets, 1); XCTAssertEqual(f.runtime.gaps, 1)
        f.runtime.setEnabled(false)
    }

    func testDisplayPathEmitsOnlySevenFiveThree() throws {
        let f = fixture(); f.runtime.setEnabled(true); f.feed(13, type: 161)
        XCTAssertEqual(try f.subtitleTypes(), [7])
        let preview = try SubtitleDisplayWire.reply(XCTUnwrap(f.subtitlePackets.first))
        let sid = try XCTUnwrap(preview.sid)
        f.runtime.receive(device: "fixture", business: 19,
            packet: try DeviceBusinessWire.encode(type: 8, json: ["sid": sid, "code": 1]))
        f.provider.onText?("镜片上的字幕", true)
        XCTAssertEqual(try f.subtitleTypes(), [7, 5])
        f.runtime.setEnabled(false)
        XCTAssertEqual(try f.subtitleTypes(), [7, 5, 3])
        XCTAssertFalse(try f.subtitleTypes().contains(1))
    }

    func testEnableAndTargetPersistButAnotherDeviceDoesNotAutoStart() throws {
        let f = fixture(); f.runtime.setEnabled(true)
        f.currentDevice = nil; f.runtime.connectionChanged()
        XCTAssertTrue(f.runtime.enabled); XCTAssertEqual(f.runtime.phase, .waitingForDevice)
        let secondProvider = Provider(), vault = Vault()
        let settings = SubtitleSettingsStore(defaults: f.defaults, credentials: vault, allowsChanges: true,
            factory: { _ in secondProvider })
        var options = CaptionOptions(); options.service = .aliyun
        options.aliyunHost = "workspace-a.cn-beijing.maas.aliyuncs.com"
        XCTAssertTrue(settings.save(options, key: "synthetic-test-only"))
        var other: String? = "another-device", sends = 0
        let restored = AlwaysOnRuntime(defaults: f.defaults, archive: f.archive, settings: settings,
            device: { other }, supportsDevice: { true }, available: { true }, suspendVoice: {}, claimDisplay: { _ in },
            sendBusiness: { _, _ in sends += 1 }, sendSubtitle: { _, _ in }, makeDecoder: { Decoder() }, scheduleTimers: false)
        restored.prepare()
        XCTAssertTrue(restored.enabled); XCTAssertEqual(restored.phase, .waitingForDevice); XCTAssertEqual(sends, 0)
        other = "fixture"; restored.connectionChanged()
        XCTAssertEqual(sends, 2)
        restored.setEnabled(false)
    }

    func testAutomaticLanguageRejectsDeepgramWithoutFallback() {
        let f = fixture()
        var deepgram = f.settings.options; deepgram.service = .deepgram
        XCTAssertTrue(f.settings.save(deepgram, key: "synthetic-deepgram-key"))
        XCTAssertFalse(f.runtime.setLanguage(.automatic, policy: .nextTask))
        XCTAssertTrue(f.runtime.error?.contains("Deepgram") == true)
        XCTAssertEqual(f.provider.starts, 0)
    }

    func testArchiveExportAndDeleteAreTextOnly() async throws {
        let f = fixture(), run = UUID(), now = Date()
        try f.archive.append(AlwaysOnTranscriptEntry(timestamp: now, runID: run, kind: .final,
            text: "可导出的文字", service: "fixture", model: "fixture", languageMode: .automatic))
        let day = f.archive.dayKey(for: now)
        let text = try await f.archive.exportText(day: day)
        XCTAssertTrue(String(decoding: try Data(contentsOf: text), as: UTF8.self).contains("可导出的文字"))
        let zip = try await f.archive.exportZIP(day: day)
        XCTAssertEqual(zip.pathExtension, "zip")
        await f.archive.load(); XCTAssertEqual(f.archive.days.map(\.day), [day])
        await f.archive.delete(day: day); XCTAssertTrue(f.archive.days.isEmpty)
    }

    private func fixture() -> Fixture { Fixture() }

    private final class Decoder: SubtitlePCMDecoder {
        func decode(_ packet: Data) -> Data? { packet.count == 240 ? Data(repeating: 1, count: 640) : nil }
        func reset() {}
    }
    @MainActor private final class Provider: CaptionASRProvider {
        var onText: ((String, Bool) -> Void)?
        var onEndpoint: (() -> Void)?
        var onReady: (() -> Void)?
        var onFailure: ((CaptionConnectionFailure) -> Void)?
        var starts = 0, stops = 0, audio: [Data] = []
        func start(options: CaptionOptions, key: String) { starts += 1; onReady?() }
        func append(_ pcm: Data) { audio.append(pcm) }
        func stop() { stops += 1 }
    }
    private final class Vault: SubtitleCredentialStorage {
        var keys: [String: String] = [:]
        func key(for options: CaptionOptions) -> String? { keys[options.credentialService + options.credentialAccount] }
        func save(_ key: String, for options: CaptionOptions) throws { keys[options.credentialService + options.credentialAccount] = key }
        func remove(for options: CaptionOptions) throws { keys.removeValue(forKey: options.credentialService + options.credentialAccount) }
    }
    @MainActor private final class Fixture {
        let name = "AlwaysOnTests.\(UUID())"
        let defaults: UserDefaults, root: URL, archive: AlwaysOnTranscriptArchive
        let settings: SubtitleSettingsStore, provider = Provider(), vault = Vault()
        var currentDevice: String? = "fixture"
        var businessPackets: [(UInt8, Data)] = [], subtitlePackets: [Data] = []
        lazy var runtime = AlwaysOnRuntime(defaults: defaults, archive: archive, settings: settings,
            device: { [unowned self] in currentDevice }, supportsDevice: { true }, available: { true },
            suspendVoice: {}, claimDisplay: { _ in },
            sendBusiness: { [unowned self] in businessPackets.append(($0, $1)) },
            sendSubtitle: { [unowned self] _, packet in try SubtitleDisplayWire.validateOutbound(packet); subtitlePackets.append(packet) },
            makeDecoder: { Decoder() }, scheduleTimers: false)
        init() {
            defaults = UserDefaults(suiteName: name)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            archive = AlwaysOnTranscriptArchive(root: root)
            let provider = provider, vault = vault
            settings = SubtitleSettingsStore(defaults: defaults, credentials: vault, allowsChanges: true, factory: { _ in provider })
            var options = CaptionOptions(); options.service = .aliyun
            options.aliyunHost = "workspace-a.cn-beijing.maas.aliyuncs.com"
            XCTAssertTrue(settings.save(options, key: "synthetic-test-only"))
        }
        func feed(_ business: UInt8, type: UInt32, json: [String: Any] = [:], bytes: Data = Data()) {
            runtime.receive(device: "fixture", business: business,
                packet: try! DeviceBusinessWire.encode(type: type, json: json, bytes: bytes))
        }
        func businessTypes(_ business: UInt8) throws -> [UInt32] {
            try businessPackets.filter { $0.0 == business }.map { try DeviceBusinessWire($0.1).type }
        }
        func subtitleTypes() throws -> [UInt32] { try subtitlePackets.map { try SubtitleDisplayWire.reply($0).type } }
        func taskID() throws -> String {
            let packet = try XCTUnwrap(businessPackets.first { $0.0 == 13 && (try? DeviceBusinessWire($0.1).type) == 162 })
            return try XCTUnwrap(try DeviceBusinessWire(packet.1).json["taskId"] as? String)
        }
    }
}
