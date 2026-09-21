import XCTest
import RayNeoCaptions
@testable import RayNeoCompanion

final class SubtitleArchiveTests:XCTestCase {
    func testMetadataTranscriptAndWAVRoundtripRejectsMismatchedIdentity() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-archive-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        var options=CaptionOptions();options.recordAudio=true
        var record=SubtitleSessionRecord(title:"合成测试",options:options)
        let journal=try CaptionJournal(root:root,id:record.id)
        try record.write(to:journal.directory)
        try journal.append(CaptionEntry(kind:.final,text:"Hello 世界"));try journal.close()
        let wav=try CaptionWAVWriter(directory:journal.directory)
        try wav.append(Data(repeating:1,count:640));try wav.close()
        record.receivedPCMBytes=640;record.finalSentences=1;record.state = .completed
        try record.write(to:journal.directory)
        XCTAssertEqual(try SubtitleSessionRecord.read(from:journal.directory),record)
        XCTAssertEqual(try SubtitleArchiveFiles.audio(in:journal.directory).count,1)
        XCTAssertEqual(try SubtitleArchiveFiles.catalog(root:root).records.count,1)
        XCTAssertTrue(try CaptionJournal.exportText(CaptionJournal.load(journal.directory)).contains("Hello 世界"))
        XCTAssertThrowsError(try record.write(to:root.appendingPathComponent(UUID().uuidString)))
    }
    @MainActor func testRunningSessionCannotDeleteRenameOrExport() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-active-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let record=SubtitleSessionRecord(title:"保留",options:CaptionOptions())
        let journal=try CaptionJournal(root:root,id:record.id);try record.write(to:journal.directory);try journal.close()
        let store=SubtitleArchiveStore(root:root);store.isActive={_ in true}
        await store.delete(record.id);await store.rename(record.id,title:"不应写入")
        do{_ = try await store.export(record.id,includingAudio:false);XCTFail("export active session")}catch{}
        XCTAssertEqual(try SubtitleSessionRecord.read(from:journal.directory).title,"保留")
    }
}
