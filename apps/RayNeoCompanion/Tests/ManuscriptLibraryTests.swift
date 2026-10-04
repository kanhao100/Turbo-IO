import XCTest
@testable import RayNeoCompanion

final class ManuscriptLibraryTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("manuscripts-\(UUID().uuidString)", isDirectory: true)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "manuscripts-tests-\(UUID().uuidString)"))
    }

    @MainActor func testCreateSelectRenameDuplicateDeleteSurviveReload() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ManuscriptLibrary(root: root, defaults: defaults)
        let first = try XCTUnwrap(library.create(title: "开场", text: "大家好。"))
        let second = try XCTUnwrap(library.create(title: "结束", text: "谢谢。"))
        XCTAssertEqual(library.manuscripts.map(\.id), [second.id, first.id])
        XCTAssertEqual(library.selectedID, second.id)
        XCTAssertTrue(library.select(first.id))
        XCTAssertTrue(library.save(id: first.id, title: " 开场白 ", text: first.text))
        XCTAssertEqual(library.manuscripts.first?.id, first.id)
        XCTAssertEqual(library.selected?.title, "开场白")
        let copy = try XCTUnwrap(library.duplicate(first.id))
        XCTAssertNotEqual(copy.id, first.id)
        XCTAssertEqual(copy.title, "开场白 副本")
        XCTAssertEqual(copy.text, first.text)
        XCTAssertEqual(copy.readingUTF8Offset, 0)
        XCTAssertEqual(library.selectedID, copy.id)
        XCTAssertTrue(library.delete(copy.id))
        XCTAssertEqual(library.selectedID, first.id)
        let restored = ManuscriptLibrary(root: root, defaults: defaults)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.manuscripts, library.manuscripts)
        XCTAssertEqual(restored.selectedID, first.id)
        XCTAssertTrue(restored.delete(first.id))
        XCTAssertTrue(restored.delete(second.id))
        XCTAssertNil(restored.selected)
        XCTAssertTrue(ManuscriptLibrary(root: root, defaults: defaults).manuscripts.isEmpty)
    }

    @MainActor func testEmptyDraftAndBoundedTitleAreSavedWithoutChangingRunningCopy() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ManuscriptLibrary(root: root, defaults: defaults)
        let draft = try XCTUnwrap(library.create(title: " \n "))
        XCTAssertEqual(draft.title, "未命名稿件")
        XCTAssertEqual(draft.text, "")
        let runningCopy = draft
        let longTitle = String(repeating: "👨‍👩‍👧‍👦", count: 120)
        XCTAssertTrue(library.save(id: draft.id, title: longTitle, text: "新的稿件"))
        let saved = try XCTUnwrap(library.selected)
        XCTAssertLessThanOrEqual(saved.title.utf8.count, 480)
        XCTAssertEqual(runningCopy.text, "")
        let duplicate = try XCTUnwrap(library.duplicate(draft.id))
        XCTAssertTrue(duplicate.title.hasSuffix(" 副本"))
        XCTAssertLessThanOrEqual(duplicate.title.utf8.count, 480)
    }

    @MainActor func testLegacyMigrationIsPerRootAndDoesNotReappearAfterDeletion() throws {
        let root = temporaryRoot(), otherRoot = temporaryRoot(), defaults = try isolatedDefaults()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let legacy = "这是一份旧演讲稿。"
        defaults.set(legacy, forKey: "companion.v1.prompter")
        let library = ManuscriptLibrary(root: root, defaults: defaults)
        let migrated = try XCTUnwrap(library.selected)
        XCTAssertEqual(migrated.title, "原提词稿")
        XCTAssertEqual(migrated.text, legacy)
        XCTAssertEqual(ManuscriptLibrary(root: root, defaults: defaults, legacyText: legacy).manuscripts.count, 1)
        XCTAssertTrue(library.delete(migrated.id))
        let restored = ManuscriptLibrary(root: root, defaults: defaults, legacyText: legacy)
        XCTAssertNil(restored.error)
        XCTAssertTrue(restored.manuscripts.isEmpty)
        XCTAssertNil(restored.selectedID)
        XCTAssertEqual(defaults.string(forKey: "companion.v1.prompter"), legacy)
        XCTAssertEqual(ManuscriptLibrary(root: otherRoot, defaults: defaults).selected?.text, legacy)
    }

    @MainActor func testEmptyMigrationIsRecordedAndOversizedLegacyIsPreservedForRetry() throws {
        let emptyRoot = temporaryRoot(), failedRoot = temporaryRoot(), defaults = try isolatedDefaults()
        defer {
            try? FileManager.default.removeItem(at: emptyRoot)
            try? FileManager.default.removeItem(at: failedRoot)
        }
        let empty = ManuscriptLibrary(root: emptyRoot, defaults: defaults)
        XCTAssertNil(empty.error)
        XCTAssertTrue(ManuscriptLibrary(root: emptyRoot, defaults: defaults, legacyText: "后来出现的旧文本").manuscripts.isEmpty)
        let oversized = String(repeating: "x", count: ManuscriptLibrary.maximumCharacters + 1)
        defaults.set(oversized, forKey: "companion.v1.prompter")
        let failed = ManuscriptLibrary(root: failedRoot, defaults: defaults)
        XCTAssertTrue(failed.error?.contains("旧提词稿未能迁移") == true)
        XCTAssertTrue(failed.manuscripts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedRoot.appendingPathComponent("library.json").path))
        XCTAssertEqual(defaults.string(forKey: "companion.v1.prompter"), oversized)
        defaults.set("修正后的旧稿", forKey: "companion.v1.prompter")
        XCTAssertEqual(ManuscriptLibrary(root: failedRoot, defaults: defaults).selected?.text, "修正后的旧稿")
    }

    @MainActor func testOversizedOrInvalidEditsLeaveMemoryAndDiskIntact() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ManuscriptLibrary(root: root, defaults: defaults)
        let original = try XCTUnwrap(library.create(title: "原稿", text: "原始正文"))
        let manifest = root.appendingPathComponent("library.json")
        let originalBytes = try Data(contentsOf: manifest)
        let tooManyCharacters = String(repeating: "a", count: ManuscriptLibrary.maximumCharacters + 1)
        let tooManyBytes = String(repeating: "👨‍👩‍👧‍👦", count: 2_000)
        for invalidText in [tooManyCharacters, tooManyBytes, "正文\0"] {
            XCTAssertFalse(library.save(id: original.id, title: "未保存标题", text: invalidText))
            XCTAssertEqual(library.selected, original)
            XCTAssertEqual(try Data(contentsOf: manifest), originalBytes)
            XCTAssertNil(library.create(title: "失败新稿", text: invalidText))
            XCTAssertEqual(library.manuscripts, [original])
        }
        XCTAssertEqual(ManuscriptLibrary(root: root, defaults: defaults).selected, original)
    }

    @MainActor func testCorruptLibraryIsPreservedAndCannotBeOverwritten() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.json"), corrupt = Data("{broken archive".utf8)
        try corrupt.write(to: url)
        let library = ManuscriptLibrary(root: root, defaults: defaults, legacyText: "不要覆盖原文件")
        XCTAssertNotNil(library.error)
        XCTAssertNil(library.create(text: "新稿件"))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertTrue(library.manuscripts.isEmpty)
    }

    @MainActor func testFailedDiskWriteKeepsExistingManuscriptsAndSelection() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ManuscriptLibrary(root: root, defaults: defaults)
        let original = try XCTUnwrap(library.create(title: "重要稿件", text: "不可丢失的正文"))
        let manifest = root.appendingPathComponent("library.json")
        let originalBytes = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let marker = manifest.appendingPathComponent("retained.txt")
        try originalBytes.write(to: marker)
        XCTAssertFalse(library.save(id: original.id, title: "失败编辑", text: "不要生效"))
        XCTAssertFalse(library.delete(original.id))
        XCTAssertNil(library.create(text: "不要生效"))
        XCTAssertEqual(library.manuscripts, [original])
        XCTAssertEqual(library.selectedID, original.id)
        XCTAssertEqual(try Data(contentsOf: marker), originalBytes)
    }

    @MainActor func testUTF8PositionRejectsSplitCharactersAndDoesNotReorder() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ManuscriptLibrary(root: root, defaults: defaults)
        let text = "中👨‍👩‍👧‍👦e\u{301}后"
        let manuscript = try XCTUnwrap(library.create(title: "Unicode", text: text))
        let another = try XCTUnwrap(library.create(title: "最近稿件", text: "另一份"))
        let valid = "中👨‍👩‍👧‍👦".utf8.count
        XCTAssertTrue(library.savePosition(id: manuscript.id, utf8Offset: valid))
        let saved = try XCTUnwrap(library.manuscripts.first { $0.id == manuscript.id })
        XCTAssertEqual(saved.modifiedAt, manuscript.modifiedAt)
        XCTAssertEqual(library.manuscripts.map(\.id), [another.id, manuscript.id])
        for badOffset in [-1, 1, 4, valid + 1, text.utf8.count + 1] {
            XCTAssertFalse(library.savePosition(id: manuscript.id, utf8Offset: badOffset))
            XCTAssertEqual(library.manuscripts.first { $0.id == manuscript.id }?.readingUTF8Offset, valid)
        }
        let restored = ManuscriptLibrary(root: root, defaults: defaults)
        XCTAssertEqual(restored.manuscripts.first { $0.id == manuscript.id }?.readingUTF8Offset, valid)
        XCTAssertTrue(restored.save(id: manuscript.id, title: "只改标题", text: text))
        XCTAssertEqual(restored.manuscripts.first { $0.id == manuscript.id }?.readingUTF8Offset, valid)
        XCTAssertTrue(restored.save(id: manuscript.id, title: "修改正文", text: "短稿"))
        XCTAssertEqual(restored.manuscripts.first { $0.id == manuscript.id }?.readingUTF8Offset, 0)
    }

    @MainActor func testImportsUTF8UTF16AndMarkdownWithoutModifyingSources() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = ManuscriptLibrary(root: root.appendingPathComponent("library"), defaults: defaults)
        let samples: [(String, Data, String)] = [
            ("开场.txt", Data("\u{FEFF}Hello 👓\r\n你好\r结束".utf8), "Hello 👓\n你好\n结束"),
            ("讲稿.TXT", try XCTUnwrap("中文\r\n下一行".data(using: .utf16)), "中文\n下一行"),
            ("提纲.md", Data("# 标题\n\n- 保留 Markdown 内容".utf8), "# 标题\n\n- 保留 Markdown 内容")
        ]
        for (name, bytes, expected) in samples {
            let source = root.appendingPathComponent(name)
            try bytes.write(to: source)
            let imported = try XCTUnwrap(library.importFile(source))
            XCTAssertEqual(imported.text, expected)
            XCTAssertEqual(imported.title, source.deletingPathExtension().lastPathComponent)
            XCTAssertEqual(library.selectedID, imported.id)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
        XCTAssertEqual(library.manuscripts.count, 3)
        XCTAssertEqual(ManuscriptLibrary(root: library.root, defaults: defaults).manuscripts, library.manuscripts)
    }

    @MainActor func testInvalidImportsAndSymlinksCannotAlterLibrary() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = ManuscriptLibrary(root: root.appendingPathComponent("library"), defaults: defaults)
        let original = try XCTUnwrap(library.create(text: "已保存稿件"))
        let samples: [(String, Data)] = [
            ("空白.txt", Data(" \n".utf8)), ("不支持.pdf", Data("text".utf8)),
            ("错误编码.txt", Data([0xFF, 0xFF, 0xFF])), ("控制字符.txt", Data([65, 0, 66])),
            ("过大.txt", Data(repeating: 65, count: ManuscriptLibrary.maximumTextBytes * 2 + 5))
        ]
        for (name, bytes) in samples {
            let source = root.appendingPathComponent(name)
            try bytes.write(to: source)
            XCTAssertNil(library.importFile(source))
            XCTAssertEqual(library.manuscripts, [original])
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
        let source = root.appendingPathComponent("真实.txt"), link = root.appendingPathComponent("链接.txt")
        try Data("不能通过符号链接导入".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertNil(library.importFile(link))
        XCTAssertEqual(library.manuscripts, [original])
    }

    @MainActor func testManuscriptCountLimitAndUnknownIdentifiersAreRejected() throws {
        let root = temporaryRoot(), defaults = try isolatedDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ManuscriptLibrary(root: root, defaults: defaults)
        for number in 0..<ManuscriptLibrary.maximumManuscripts {
            XCTAssertNotNil(library.create(title: "稿件 \(number)"))
        }
        let snapshot = library.manuscripts, selection = library.selectedID
        XCTAssertNil(library.create(text: "第 101 份"))
        XCTAssertNil(library.duplicate(try XCTUnwrap(selection)))
        let missing = UUID()
        XCTAssertFalse(library.select(missing))
        XCTAssertFalse(library.save(id: missing, title: "未知", text: "未知"))
        XCTAssertFalse(library.delete(missing))
        XCTAssertFalse(library.savePosition(id: missing, utf8Offset: 0))
        XCTAssertEqual(library.manuscripts, snapshot)
        XCTAssertEqual(library.selectedID, selection)
        XCTAssertEqual(ManuscriptLibrary(root: root, defaults: defaults).manuscripts, snapshot)
    }
}
