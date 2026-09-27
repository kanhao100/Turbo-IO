import XCTest
@testable import RayNeoCaptions

final class CaptionStorageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("caption-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testJournalRoundTripAndExplicitUnfinishedTail() throws {
        let root = try temporaryDirectory(), journal = try CaptionJournal(root: root, id: UUID())
        let entries = [CaptionEntry(kind: .started, text: "test"), CaptionEntry(kind: .final, text: "你好\n世界"),
                       CaptionEntry(kind: .unfinished, text: "not final"), CaptionEntry(kind: .stopped, text: "user")]
        for entry in entries { try journal.append(entry) }
        try journal.close(); try journal.close()
        XCTAssertEqual(try CaptionJournal.load(journal.directory), entries)
        XCTAssertThrowsError(try journal.append(entries[0]))
        XCTAssertTrue(CaptionJournal.exportText(entries).contains("[unfinished] not final"))
    }
    func testNoAudioFileExistsForTextOnlyJournal() throws {
        let journal = try CaptionJournal(root: temporaryDirectory(), id: UUID())
        try journal.append(CaptionEntry(kind: .final, text: "only text")); try journal.close()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journal.directory.path), ["captions.jsonl"])
    }
    func testKilledWriteTailIsIgnoredWithoutModifyingOriginal() throws {
        let journal = try CaptionJournal(root: temporaryDirectory(), id: UUID())
        let entry = CaptionEntry(kind: .final, text: "committed")
        try journal.append(entry); try journal.close()
        let url = journal.directory.appendingPathComponent("captions.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"torn\":".utf8)); try handle.close()
        let original = try Data(contentsOf: url)
        XCTAssertEqual(try CaptionJournal.load(journal.directory), [entry])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testMalformedCommittedLineIsNotSilentlySkipped() throws {
        let root = try temporaryDirectory(), journal = try CaptionJournal(root: root, id: UUID())
        try journal.close()
        try Data("not-json\n".utf8).write(to: journal.directory.appendingPathComponent("captions.jsonl"))
        XCTAssertThrowsError(try CaptionJournal.load(journal.directory))
    }
    func testEscapedControlCharactersCanBeReadBack() throws {
        let journal = try CaptionJournal(root: temporaryDirectory(), id: UUID())
        let entry = CaptionEntry(kind: .final, text: String(repeating: "\u{01}", count: 32_768))
        try journal.append(entry); try journal.close()
        XCTAssertEqual(try CaptionJournal.load(journal.directory), [entry])
    }
    func testDuplicateSessionCannotOverwriteHistory() throws {
        let root = try temporaryDirectory(), id = UUID()
        let journal = try CaptionJournal(root: root, id: id)
        try journal.append(CaptionEntry(kind: .final, text: "keep me")); try journal.close()
        XCTAssertThrowsError(try CaptionJournal(root: root, id: id))
        XCTAssertEqual(try CaptionJournal.load(journal.directory).first?.text, "keep me")
    }
    func testJournalRejectsOversizeSentencesAndSymlinks() throws {
        let root = try temporaryDirectory(), journal = try CaptionJournal(root: root, id: UUID())
        XCTAssertThrowsError(try journal.append(CaptionEntry(kind: .final, text: String(repeating: "x", count: 32_769))))
        try journal.close()
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link.appendingPathComponent("captions.jsonl"),
                                                  withDestinationURL: journal.directory.appendingPathComponent("captions.jsonl"))
        XCTAssertThrowsError(try CaptionJournal.load(link))
    }
    func testWAVRotationHasCorrectHeadersAndExactReceivedPCM() throws {
        let writer = try CaptionWAVWriter(directory: temporaryDirectory(), segmentSeconds: 1)
        let pcm = Data((0..<35_000).map { UInt8($0 % 251) })
        try writer.append(pcm); try writer.close()
        XCTAssertEqual(writer.files.count, 2)
        var combined = Data()
        for (index, url) in writer.files.enumerated() {
            let data = try Data(contentsOf: url), count = index == 0 ? 32_000 : 3_000
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
            XCTAssertEqual(uint32(data, at: 4), UInt32(count + 36))
            XCTAssertEqual(uint32(data, at: 24), 16_000)
            XCTAssertEqual(uint32(data, at: 28), 32_000)
            XCTAssertEqual(uint32(data, at: 40), UInt32(count))
            XCTAssertEqual(data.count, count + 44)
            combined.append(data.dropFirst(44))
        }
        XCTAssertEqual(combined, pcm)
    }
    func testGapStartsNewPieceWithoutInventingSilence() throws {
        let writer = try CaptionWAVWriter(directory: temporaryDirectory())
        try writer.append(Data([1, 2])); try writer.finishSegment()
        try writer.append(Data([3, 4])); try writer.close(); try writer.close()
        XCTAssertEqual(writer.files.count, 2)
        XCTAssertEqual(try Data(contentsOf: writer.files[0]).count, 46)
        XCTAssertEqual(try Data(contentsOf: writer.files[1]).count, 46)
        XCTAssertThrowsError(try writer.append(Data([5, 6])))
    }
    func testWAVBoundsAndEmptySessionDoNotProduceFalseRecording() throws {
        let writer = try CaptionWAVWriter(directory: temporaryDirectory(), byteLimit: 4)
        XCTAssertThrowsError(try writer.append(Data()))
        XCTAssertThrowsError(try writer.append(Data([1])))
        XCTAssertTrue(writer.files.isEmpty)
        try writer.append(Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try writer.append(Data([5, 6])))
        try writer.close(); XCTAssertEqual(try Data(contentsOf: writer.files[0]).count, 48)
    }
    func testOpenWAVHeaderIsCheckpointedBeforeNormalClose() throws {
        let writer = try CaptionWAVWriter(directory: temporaryDirectory())
        try writer.append(Data(repeating: 7, count: 32_000))
        let file = try XCTUnwrap(writer.files.first)
        XCTAssertEqual(uint32(try Data(contentsOf: file), at: 40), 32_000)
        try writer.close()
    }
    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
    }
}
