import Foundation
import Combine
import Darwin

struct PrompterManuscript: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var createdAt = Date()
    var modifiedAt = Date()
    var readingUTF8Offset = 0
}

/// Each operation commits a complete snapshot before changing the visible library.
/// A running prompter uses its own value copy, so editing a saved draft cannot alter it.
@MainActor final class ManuscriptLibrary: ObservableObject {
    static let maximumManuscripts = 100
    static let maximumCharacters = 12_000
    static let maximumTextBytes = 48_000
    static let maximumLibraryTextBytes = 8 * 1_024 * 1_024

    @Published private(set) var manuscripts: [PrompterManuscript] = []
    @Published private(set) var selectedID: UUID?
    @Published var error: String?
    var selected: PrompterManuscript? { manuscripts.first { $0.id == selectedID } }
    let root: URL

    private static let maximumFileBytes = 16 * 1_024 * 1_024
    private var storageReady = false
    private var legacyMigrated = false
    private var manifestURL: URL { root.appendingPathComponent("library.json") }

    private struct Manifest: Codable {
        var version = 1
        var manuscripts: [PrompterManuscript]
        var selectedID: UUID?
        var legacyMigrated: Bool
    }

    private enum Failure: LocalizedError {
        case corrupt, notReady, missing, limit, position, unsupported, encoding, emptyImport
        var errorDescription: String? {
            switch self {
            case .corrupt: return "稿件库读取失败，原文件已保留；请检查存储后重新打开。"
            case .notReady: return "稿件库尚未成功读取，未覆盖原文件。"
            case .missing: return "这份稿件已经不存在，请重新选择。"
            case .limit: return "最多保存 100 份稿件；每份正文最多 12,000 个字符和 48,000 字节。"
            case .position: return "阅读位置不在有效的文字边界，未保存。"
            case .unsupported: return "目前支持导入 UTF-8 或 UTF-16 编码的 TXT、MD 文本。"
            case .encoding: return "无法识别文字编码，请另存为 UTF-8 文本后导入。"
            case .emptyImport: return "导入文件没有可用正文；可通过新建稿件创建空白草稿。"
            }
        }
    }

    init(root: URL? = nil, defaults: UserDefaults = .standard, legacyText: String = "") {
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrompterLibraryV1", isDirectory: true)).standardizedFileURL
        var migratingLegacy = false
        do {
            guard self.root.isFileURL else { throw Failure.corrupt }
            try verifyRootIfPresent()
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let manifest = try JSONDecoder().decode(Manifest.self,
                    from: Self.readBounded(manifestURL, limit: Self.maximumFileBytes))
                guard manifest.version == 1 else { throw Failure.corrupt }
                try Self.validate(manifest.manuscripts, selectedID: manifest.selectedID)
                manuscripts = Self.sorted(manifest.manuscripts)
                selectedID = manifest.selectedID
                legacyMigrated = manifest.legacyMigrated
                storageReady = true
            } else {
                storageReady = true
            }
            if !legacyMigrated {
                let oldText = legacyText.isEmpty ? (defaults.string(forKey: "companion.v1.prompter") ?? "") : legacyText
                var candidate = manuscripts
                var candidateSelection = selectedID
                if !oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    migratingLegacy = true
                    let migrated = PrompterManuscript(title: "原提词稿", text: oldText)
                    candidate.append(migrated)
                    if candidateSelection == nil { candidateSelection = migrated.id }
                }
                // Even an empty migration is recorded, so deleting the imported draft
                // cannot cause the old UserDefaults text to reappear on the next launch.
                try persist(candidate, selectedID: candidateSelection, migrated: true)
                manuscripts = Self.sorted(candidate)
                selectedID = candidateSelection
                legacyMigrated = true
            }
        } catch {
            storageReady = false
            let detail = (error as? Failure)?.localizedDescription ?? "稿件库未能打开，原文件和旧稿件已保留；请检查可用空间与文件权限后重试。"
            self.error = migratingLegacy ? "旧提词稿未能迁移：\(detail) 旧文本与原稿件库已保留。" : detail
        }
    }

    @discardableResult func create(title: String = "新稿件", text: String = "") -> PrompterManuscript? {
        let manuscript = PrompterManuscript(title: Self.title(title), text: text)
        guard commit(manuscripts + [manuscript], selectedID: manuscript.id) else { return nil }
        return manuscript
    }

    @discardableResult func save(id: UUID, title: String, text: String) -> Bool {
        guard let index = manuscripts.firstIndex(where: { $0.id == id }) else { return fail(.missing) }
        var candidate = manuscripts
        let cleanTitle = Self.title(title)
        if candidate[index].title == cleanTitle, candidate[index].text == text { error = nil; return true }
        if candidate[index].text != text { candidate[index].readingUTF8Offset = 0 }
        candidate[index].title = cleanTitle
        candidate[index].text = text
        candidate[index].modifiedAt = Date()
        return commit(candidate, selectedID: selectedID)
    }

    @discardableResult func select(_ id: UUID) -> Bool {
        guard manuscripts.contains(where: { $0.id == id }) else { return fail(.missing) }
        return commit(manuscripts, selectedID: id)
    }

    @discardableResult func duplicate(_ id: UUID) -> PrompterManuscript? {
        guard let original = manuscripts.first(where: { $0.id == id }) else { _ = fail(.missing); return nil }
        let copy = PrompterManuscript(title: Self.title(original.title, maximumCharacters: 116, maximumBytes: 473) + " 副本", text: original.text)
        guard commit(manuscripts + [copy], selectedID: copy.id) else { return nil }
        return copy
    }

    @discardableResult func delete(_ id: UUID) -> Bool {
        guard manuscripts.contains(where: { $0.id == id }) else { return fail(.missing) }
        let candidate = manuscripts.filter { $0.id != id }
        let selection = selectedID == id ? candidate.first?.id : selectedID
        return commit(candidate, selectedID: selection)
    }

    @discardableResult func savePosition(id: UUID, utf8Offset: Int) -> Bool {
        guard let index = manuscripts.firstIndex(where: { $0.id == id }) else { return fail(.missing) }
        guard Self.isValidPosition(utf8Offset, in: manuscripts[index].text) else { return fail(.position) }
        if manuscripts[index].readingUTF8Offset == utf8Offset { error = nil; return true }
        var candidate = manuscripts
        candidate[index].readingUTF8Offset = utf8Offset
        // Reading a draft does not change its editorial date or move it in the list.
        return commit(candidate, selectedID: selectedID)
    }

    /// A bounded coordinated read; the original file is neither moved nor modified.
    /// Markdown is retained as text so importing does not silently change the script.
    @discardableResult func importFile(_ source: URL) -> PrompterManuscript? {
        guard source.isFileURL, ["txt", "md"].contains(source.pathExtension.lowercased()) else {
            _ = fail(.unsupported); return nil
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            var result: Result<Data, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                result = Result { try Self.readBounded(url, limit: Self.maximumTextBytes * 2 + 4) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw Failure.corrupt }
            let data = try result.get()
            let decoded: String?
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                decoded = String(data: data, encoding: .utf16)
            } else { decoded = String(data: data, encoding: .utf8) }
            guard let decoded else { throw Failure.encoding }
            let text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let clean = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyImport }
            return create(title: source.deletingPathExtension().lastPathComponent, text: clean)
        } catch {
            self.error = (error as? Failure)?.localizedDescription ?? "稿件导入失败，请确认文件已下载到本机。原文件未修改。"
            return nil
        }
    }

    private func commit(_ candidate: [PrompterManuscript], selectedID: UUID?) -> Bool {
        guard storageReady else { return fail(.notReady) }
        do {
            try persist(candidate, selectedID: selectedID, migrated: legacyMigrated)
            manuscripts = Self.sorted(candidate)
            self.selectedID = selectedID
            error = nil
            return true
        } catch {
            self.error = (error as? Failure)?.localizedDescription ?? "稿件变更未保存，请检查可用空间后重试；原稿件保持不变。"
            return false
        }
    }

    private func persist(_ candidate: [PrompterManuscript], selectedID: UUID?, migrated: Bool) throws {
        try Self.validate(candidate, selectedID: selectedID)
        try verifyRootIfPresent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var protectedRoot = root, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let info = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw Failure.corrupt }
        }
        let manifest = Manifest(manuscripts: Self.sorted(candidate), selectedID: selectedID, legacyMigrated: migrated)
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Self.maximumFileBytes else { throw Failure.limit }
        try data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func verifyRootIfPresent() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw Failure.corrupt }
    }

    private static func validate(_ manuscripts: [PrompterManuscript], selectedID: UUID?) throws {
        guard manuscripts.count <= maximumManuscripts else { throw Failure.limit }
        guard Set(manuscripts.map(\.id)).count == manuscripts.count,
              selectedID == nil || manuscripts.contains(where: { $0.id == selectedID }) else { throw Failure.corrupt }
        var bytes = 0
        for manuscript in manuscripts {
            guard manuscript.title.count <= 120, !manuscript.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  manuscript.title.utf8.count <= 480,
                  manuscript.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  manuscript.modifiedAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.corrupt }
            guard manuscript.text.count <= maximumCharacters,
                  manuscript.text.utf8.count <= maximumTextBytes else { throw Failure.limit }
            guard !manuscript.text.unicodeScalars.contains(where: {
                $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13
            }) else { throw Failure.encoding }
            guard isValidPosition(manuscript.readingUTF8Offset, in: manuscript.text) else { throw Failure.position }
            bytes += manuscript.text.utf8.count
            guard bytes <= maximumLibraryTextBytes else { throw Failure.limit }
        }
    }

    static func isValidPosition(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf8.count else { return false }
        if offset == 0 { return true }
        var bytes = 0
        for character in text {
            bytes += String(character).utf8.count
            if bytes == offset { return true }
            if bytes > offset { return false }
        }
        return false
    }

    private static func title(_ title: String, maximumCharacters: Int = 120, maximumBytes: Int = 480) -> String {
        let clean = title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = "", bytes = 0
        for character in clean.prefix(maximumCharacters) {
            let length = String(character).utf8.count
            guard bytes + length <= maximumBytes else { break }
            bounded.append(character); bytes += length
        }
        return bounded.isEmpty ? "未命名稿件" : bounded
    }

    private static func sorted(_ manuscripts: [PrompterManuscript]) -> [PrompterManuscript] {
        manuscripts.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func fail(_ failure: Failure) -> Bool { error = failure.localizedDescription; return false }

    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw Failure.corrupt }
        guard let size = info.fileSize, size >= 0, size <= limit else { throw Failure.limit }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.corrupt }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size == size else { throw Failure.corrupt }
        var data = Data()
        while let block = try handle.read(upToCount: min(65_536, limit - data.count + 1)), !block.isEmpty {
            guard data.count + block.count <= limit else { throw Failure.limit }
            data.append(block)
        }
        var after = stat()
        guard data.count == size, fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw Failure.corrupt
        }
        return data
    }
}
