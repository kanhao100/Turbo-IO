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

    func testInvalidDecodedFrameStopsOnlyTheCurrentTaskWithExplicitError() throws {
        let f = fixture(); f.runtime.setEnabled(true); f.feed(13, type: 161)
        f.decoder.acceptsPackets = false
        f.feed(13, type: 163, json: ["taskId": try f.taskID(), "frameCount": 1],
               bytes: Data(repeating: 1, count: 240))
        XCTAssertFalse(f.runtime.activeTask)
        XCTAssertEqual(f.runtime.phase, .error)
        XCTAssertTrue(f.runtime.error?.contains("Opus") == true)
        XCTAssertEqual(f.provider.stops, 1)
        XCTAssertTrue(try f.businessTypes(13).contains(166))
        XCTAssertTrue(try f.businessTypes(13).contains(168))
    }

    func testDisplayPathEmitsOnlySevenFiveThree() throws {
        let f = fixture(); f.runtime.setEnabled(true); f.feed(13, type: 161)
        XCTAssertEqual(try f.subtitleTypes(), [7])
        let preview = try SubtitleDisplayWire.reply(XCTUnwrap(f.subtitlePackets.first))
        let sid = try XCTUnwrap(preview.sid)
        f.runtime.receive(device: "fixture", business: 19,
            packet: try DeviceBusinessWire.encode(type: 8, json: ["sid": sid, "code": 1]))
        f.provider.onText?("镜片上的字幕", true)
        // The ACK flushes the initial listening prompt; the final ASR result is a
        // second text update. Both must stay on the display-only type-5 path.
        XCTAssertEqual(try f.subtitleTypes(), [7, 5, 5])
        f.runtime.setEnabled(false)
        XCTAssertEqual(try f.subtitleTypes(), [7, 5, 5, 3])
        XCTAssertFalse(try f.subtitleTypes().contains(1))
    }

    func testLensFailureDoesNotStopTextTranscription() throws {
        let f = fixture(); f.subtitleSendFails = true
        f.runtime.setEnabled(true); f.feed(13, type: 161)
        XCTAssertTrue(f.runtime.activeTask)
        XCTAssertTrue(f.runtime.error?.contains("镜片") == true)
        f.feed(13, type: 163, json: ["taskId": try f.taskID(), "frameCount": 1],
               bytes: Data(repeating: 1, count: 240))
        XCTAssertEqual(f.provider.audio.count, 1)
        f.provider.onText?("镜片失败也要保存文字", true)
        XCTAssertEqual(f.runtime.todaySentences, 1)
        XCTAssertTrue(f.runtime.activeTask)
        f.runtime.setEnabled(false)
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

    func testApplyPoliciesGenerationIsolationAndTwoSecondReconnectBuffer() async throws {
        let f = fixture(); f.runtime.setEnabled(true); f.feed(13, type: 161)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.provider.startedOptions.last?.languageMode, .automatic)

        XCTAssertFalse(f.runtime.setLanguage(.fixed(localeIdentifier: "zh-CN"), policy: .cancel))
        XCTAssertEqual(f.runtime.languageMode, .automatic)
        XCTAssertTrue(f.runtime.setLanguage(.fixed(localeIdentifier: "zh-CN"), policy: .nextTask))
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.provider.startedOptions.last?.languageMode, .automatic)

        let staleText = f.provider.onText
        f.provider.autoReady = false
        XCTAssertTrue(f.runtime.setLanguage(.fixed(localeIdentifier: "en-US"), policy: .immediately))
        XCTAssertEqual(f.provider.starts, 2); XCTAssertEqual(f.provider.stops, 1)
        XCTAssertEqual(f.provider.startedOptions.last?.languageMode, .fixed(localeIdentifier: "en-US"))
        staleText?("迟到的旧代结果", true)
        XCTAssertTrue(f.runtime.recent.isEmpty)

        let task = try f.taskID()
        for _ in 0..<101 {
            f.feed(13, type: 163, json: ["taskId": task, "frameCount": 1],
                   bytes: Data(repeating: 2, count: 240))
        }
        XCTAssertTrue(f.provider.audio.isEmpty)
        f.provider.onReady?()
        XCTAssertEqual(f.provider.audio.count, 100)
        XCTAssertEqual(f.runtime.gaps, 1)
        let entries = try await f.archive.entries(for: f.archive.dayKey(for: f.clock.date))
        XCTAssertEqual(entries.filter { $0.kind == .gap }.count, 1)
        XCTAssertTrue(entries.contains { $0.kind == .system && $0.text.contains("立即生效") })
        f.runtime.setEnabled(false)
    }

    func testTaskEndingBeforeCloudReadyRecordsUntranscribedBuffer() async throws {
        let f = fixture(); f.provider.autoReady = false
        f.runtime.setEnabled(true); f.feed(13, type: 161)
        f.feed(13, type: 163, json: ["taskId": try f.taskID(), "frameCount": 1],
               bytes: Data(repeating: 2, count: 240))
        XCTAssertTrue(f.provider.audio.isEmpty)
        f.feed(13, type: 165)
        XCTAssertEqual(f.runtime.phase, .waitingForA1)
        XCTAssertEqual(f.runtime.gaps, 1)
        let entries = try await f.archive.entries(for: f.archive.dayKey(for: f.clock.date))
        XCTAssertTrue(entries.contains { $0.kind == .gap && $0.text.contains("内存缓冲") })
        f.runtime.setEnabled(false)
    }

    func testImmediateSettingsApplyPreservesExistingReconnectBuffer() throws {
        let f = fixture(); f.provider.autoReady = false
        f.runtime.setEnabled(true); f.feed(13, type: 161)
        f.feed(13, type: 163, json: ["taskId": try f.taskID(), "frameCount": 1],
               bytes: Data(repeating: 2, count: 240))
        XCTAssertTrue(f.provider.audio.isEmpty)
        XCTAssertTrue(f.runtime.setLanguage(.fixed(localeIdentifier: "zh-CN"), policy: .immediately))
        f.provider.onReady?()
        XCTAssertEqual(f.provider.audio.count, 1)
        XCTAssertEqual(f.runtime.gaps, 0)
        f.runtime.setEnabled(false)
    }

    func testServiceSettingsCancelNextTaskAndImmediateApply() throws {
        let f = fixture(); f.runtime.setEnabled(true); f.feed(13, type: 161)
        var eleven = f.settings.options
        eleven.service = .elevenLabs
        XCTAssertFalse(f.runtime.applySpeechSettings(eleven, key: "synthetic-eleven-key", policy: .cancel))
        XCTAssertEqual(f.settings.options.service, .aliyun)
        XCTAssertTrue(f.runtime.applySpeechSettings(eleven, key: "synthetic-eleven-key", policy: .nextTask))
        XCTAssertEqual(f.settings.options.service, .elevenLabs)
        XCTAssertEqual(f.provider.starts, 1)
        XCTAssertEqual(f.provider.startedOptions.last?.service, .aliyun)

        var azure = eleven
        azure.service = .azure; azure.region = "eastus"
        XCTAssertTrue(f.runtime.applySpeechSettings(azure, key: "synthetic-azure-key", policy: .immediately))
        XCTAssertEqual(f.settings.options.service, .azure)
        XCTAssertEqual(f.provider.starts, 2)
        XCTAssertEqual(f.provider.startedOptions.last?.service, .azure)
        XCTAssertEqual(f.provider.startedOptions.last?.languageMode, .automatic)
        f.runtime.setEnabled(false)
    }

    func testStorageFailureDisablesPersistentRuntimeAndSendsAllOffCommands() throws {
        let f = fixture()
        try Data("not a directory".utf8).write(to: f.root, options: .atomic)
        f.runtime.setEnabled(true); f.feed(13, type: 161)
        XCTAssertFalse(f.runtime.enabled)
        XCTAssertFalse(f.runtime.activeTask)
        XCTAssertEqual(f.runtime.phase, .error)
        XCTAssertTrue(f.runtime.error?.contains("存储失败") == true)
        let lifeLog = try f.businessTypes(15)
        XCTAssertGreaterThanOrEqual(lifeLog.filter { $0 == 20 }.count, 4)
        XCTAssertTrue(try f.businessTypes(13).contains(168))
    }

    func testInterruptedMarkerIsRecoveredAsGapOnNextLaunch() async throws {
        let f = fixture(); f.runtime.setEnabled(true); f.feed(13, type: 161)
        let restored = f.makeAdditionalRuntime()
        let entries = try await f.archive.entries(for: f.archive.dayKey(for: f.clock.date))
        XCTAssertTrue(entries.contains { $0.kind == .gap && $0.text.contains("App 上次运行被中断") })
        XCTAssertTrue(restored.enabled)
        restored.setEnabled(false); f.runtime.setEnabled(false)
    }

    func testTornJSONLTailIsRemovedBeforeRecoveryAppend() async throws {
        let f = fixture(), run = UUID(), day = f.archive.dayKey(for: f.clock.date)
        try f.archive.append(AlwaysOnTranscriptEntry(timestamp: f.clock.date, runID: run, kind: .final,
            text: "崩溃前完整句", service: "fixture", model: "fixture", languageMode: .automatic))
        let file = f.root.appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("entries-\(run.uuidString.lowercased()).jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"incomplete":"#.utf8)); try handle.close()
        f.clock.date.addTimeInterval(1)
        try f.archive.append(AlwaysOnTranscriptEntry(timestamp: f.clock.date, runID: run, kind: .gap,
            text: "恢复后的缺口", service: "fixture", model: "fixture", languageMode: .automatic))
        let entries = try await f.archive.entries(for: day)
        XCTAssertEqual(entries.map(\.text), ["崩溃前完整句", "恢复后的缺口"])
    }

    func testTimeZoneChangeKeepsUnfinishedTextInPreviouslyActiveDay() async throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T00:30:00Z"))
        let f = fixture(date: start, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        f.runtime.setEnabled(true); f.feed(13, type: 161)
        f.provider.onText?("跨时区前尚未定稿", false)
        f.clock.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -7_200))
        f.runtime.tick()
        let oldEntries = try await f.archive.entries(for: "2026-01-02")
        let newEntries = try await f.archive.entries(for: "2026-01-01")
        XCTAssertTrue(oldEntries.contains { $0.kind == .unfinished && $0.text == "跨时区前尚未定稿" })
        XCTAssertTrue(newEntries.contains { $0.kind == .system && $0.text.contains("自然日") })
        f.runtime.setEnabled(false)
    }

    func testMidnightRollsFinalsIntoNewLocalDay() async throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T23:59:00Z"))
        let f = fixture(date: start, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        f.runtime.setEnabled(true); f.feed(13, type: 161)
        f.provider.onText?("午夜前临时稿", false)
        f.clock.date.addTimeInterval(120); f.runtime.tick()
        f.provider.onText?("午夜后定稿", true)
        let oldEntries = try await f.archive.entries(for: "2026-01-01")
        let newEntries = try await f.archive.entries(for: "2026-01-02")
        XCTAssertTrue(oldEntries.contains { $0.kind == .unfinished && $0.text == "午夜前临时稿" })
        XCTAssertTrue(newEntries.contains { $0.kind == .final && $0.text == "午夜后定稿" })
        XCTAssertEqual(f.runtime.todaySentences, 1)
        f.runtime.setEnabled(false)
    }

    func testOrdinarySubtitleShortcutIsLoggedButCannotPreemptAlwaysOn() throws {
        let f = fixture(); f.runtime.setEnabled(true)
        let before = f.businessPackets.count
        f.runtime.receive(device: "fixture", business: 19,
            packet: try DeviceBusinessWire.encode(type: 1, json: ["sid": "ordinary-caption-shortcut"]))
        XCTAssertEqual(f.businessPackets.count, before)
        XCTAssertTrue(f.runtime.events.contains { $0.contains("全天智记占用") })
        XCTAssertEqual(f.runtime.phase, .waitingForA1)
        f.runtime.setEnabled(false)
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

    private func fixture(date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> Fixture {
        Fixture(date: date, timeZone: timeZone)
    }

    private final class Decoder: SubtitlePCMDecoder {
        var acceptsPackets = true
        func decode(_ packet: Data) -> Data? { acceptsPackets && packet.count == 240 ? Data(repeating: 1, count: 640) : nil }
        func reset() {}
    }
    @MainActor private final class Provider: CaptionASRProvider {
        var onText: ((String, Bool) -> Void)?
        var onEndpoint: (() -> Void)?
        var onReady: (() -> Void)?
        var onFailure: ((CaptionConnectionFailure) -> Void)?
        var starts = 0, stops = 0, audio: [Data] = [], startedOptions: [CaptionOptions] = []
        var autoReady = true
        func start(options: CaptionOptions, key: String) {
            starts += 1; startedOptions.append(options)
            if autoReady { onReady?() }
        }
        func append(_ pcm: Data) { audio.append(pcm) }
        func stop() { stops += 1 }
    }
    private final class Vault: SubtitleCredentialStorage {
        var keys: [String: String] = [:]
        func key(for options: CaptionOptions) -> String? { keys[options.credentialService + options.credentialAccount] }
        func save(_ key: String, for options: CaptionOptions) throws { keys[options.credentialService + options.credentialAccount] = key }
        func remove(for options: CaptionOptions) throws { keys.removeValue(forKey: options.credentialService + options.credentialAccount) }
    }
    private final class Clock {
        var date: Date
        var uptime: TimeInterval = 100
        var timeZone: TimeZone
        init(date: Date, timeZone: TimeZone) { self.date = date; self.timeZone = timeZone }
    }
    @MainActor private final class Fixture {
        let name = "AlwaysOnTests.\(UUID())"
        let defaults: UserDefaults, root: URL, archive: AlwaysOnTranscriptArchive
        let settings: SubtitleSettingsStore, provider = Provider(), vault = Vault(), decoder = Decoder(), clock: Clock
        var currentDevice: String? = "fixture"
        var businessPackets: [(UInt8, Data)] = [], subtitlePackets: [Data] = []
        var subtitleSendFails = false
        lazy var runtime = AlwaysOnRuntime(defaults: defaults, archive: archive, settings: settings,
            device: { [unowned self] in currentDevice }, supportsDevice: { true }, available: { true },
            suspendVoice: {}, claimDisplay: { _ in },
            sendBusiness: { [unowned self] in businessPackets.append(($0, $1)) },
            sendSubtitle: { [unowned self] _, packet in
                if subtitleSendFails { throw DeviceFeatureError.disconnected }
                try SubtitleDisplayWire.validateOutbound(packet); subtitlePackets.append(packet)
            }, makeDecoder: { [unowned self] in decoder },
            uptime: { [unowned self] in clock.uptime }, dateNow: { [unowned self] in clock.date },
            scheduleTimers: false)
        init(date: Date, timeZone: TimeZone) {
            let runtimeClock = Clock(date: date, timeZone: timeZone)
            clock = runtimeClock
            defaults = UserDefaults(suiteName: name)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            archive = AlwaysOnTranscriptArchive(root: root, calendar: Calendar(identifier: .gregorian),
                timeZone: { runtimeClock.timeZone })
            let provider = provider, vault = vault
            settings = SubtitleSettingsStore(defaults: defaults, credentials: vault, allowsChanges: true, factory: { _ in provider })
            var options = CaptionOptions(); options.service = .aliyun
            options.aliyunHost = "workspace-a.cn-beijing.maas.aliyuncs.com"
            XCTAssertTrue(settings.save(options, key: "synthetic-test-only"))
        }
        func makeAdditionalRuntime() -> AlwaysOnRuntime {
            AlwaysOnRuntime(defaults: defaults, archive: archive, settings: settings,
                device: { [unowned self] in currentDevice }, supportsDevice: { true }, available: { true },
                suspendVoice: {}, claimDisplay: { _ in },
                sendBusiness: { [unowned self] in businessPackets.append(($0, $1)) },
                sendSubtitle: { [unowned self] _, packet in
                    try SubtitleDisplayWire.validateOutbound(packet); subtitlePackets.append(packet)
                }, makeDecoder: { [unowned self] in decoder },
                uptime: { [unowned self] in clock.uptime }, dateNow: { [unowned self] in clock.date },
                scheduleTimers: false)
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
