import XCTest
@testable import RayNeoCompanion

final class SubtitleLatencyDiagnosticsTests: XCTestCase {
    @MainActor func testRecordsBoundedStageTimingWithoutContent() {
        let name = "subtitle-latency-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let latency = SubtitleLatencyDiagnostics(defaults: defaults)
        latency.setEnabled(true)
        latency.sessionStarted(at: 10)
        latency.audioStartAccepted(at: 10.1)
        latency.cloudStarted(at: 10.15)
        latency.cloudReady(at: 10.25)
        latency.audioArrived(callbackAt: 10.3, handledAt: 10.31)
        latency.audioArrived(callbackAt: 10.4, handledAt: 10.45)
        latency.resultReceived(at: 10.7)
        latency.resultSubmittedToGlasses(at: 10.72)

        XCTAssertEqual(latency.snapshot(.handshakeToFirstAudio).last, 200)
        XCTAssertEqual(latency.snapshot(.audioArrivalInterval).last, 100)
        XCTAssertEqual(latency.snapshot(.appDispatch).count, 2)
        XCTAssertEqual(latency.snapshot(.appDispatch).average, 30)
        XCTAssertEqual(latency.snapshot(.cloudReady).last, 100)
        XCTAssertEqual(latency.snapshot(.firstAudioToFirstResult).last, 400)
        XCTAssertEqual(latency.snapshot(.audioToResult).last, 300)
        XCTAssertEqual(latency.snapshot(.resultToGlassesSubmit).last, 20)
        XCTAssertTrue(latency.report.contains("不包含音频、字幕正文、密钥"))
        XCTAssertLessThan(latency.report.utf8.count, 2_048)
    }

    @MainActor func testEnablementPersistsButMeasurementsDoNot() {
        let name = "subtitle-latency-persistence-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = SubtitleLatencyDiagnostics(defaults: defaults)
        first.setEnabled(true); first.sessionStarted(at: 1); first.cloudStarted(at: 1.5); first.cloudReady(at: 2)

        let relaunched = SubtitleLatencyDiagnostics(defaults: defaults)
        XCTAssertTrue(relaunched.enabled)
        XCTAssertEqual(relaunched.sessionCount, 0)
        XCTAssertEqual(relaunched.snapshot(.cloudReady).count, 0)
        relaunched.setEnabled(false)
        XCTAssertFalse(SubtitleLatencyDiagnostics(defaults: defaults).enabled)
    }

    @MainActor func testDisabledExperimentCollectsNothing() {
        let name = "latency-disabled-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let latency = SubtitleLatencyDiagnostics(defaults: defaults)
        latency.sessionStarted(at: 1); latency.audioArrived(callbackAt: 2, handledAt: 3)
        latency.resultReceived(at: 4); latency.resultSubmittedToGlasses(at: 5)
        XCTAssertEqual(latency.sessionCount, 0)
        XCTAssertTrue(latency.results.isEmpty)
    }

    @MainActor func testStoppedSessionReportsMissingAudioAndResult() {
        let name = "latency-missing-stages-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let latency = SubtitleLatencyDiagnostics(defaults: defaults)
        latency.setEnabled(true); latency.sessionStarted(at: 1); latency.sessionStopped()
        XCTAssertTrue(latency.assessment.contains("未收到有效眼镜音频"))
        XCTAssertTrue(latency.assessment.contains("没有收到识别结果"))
        XCTAssertTrue(latency.report.contains("noAudio=1 noResult=1"))
    }
}
