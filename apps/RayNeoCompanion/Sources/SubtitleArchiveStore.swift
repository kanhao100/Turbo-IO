import Foundation
import Combine
import ZIPFoundation
import RayNeoCaptions

struct SubtitleAudioFile: Identifiable {
    let url: URL
    let duration: TimeInterval
    var id: String { url.lastPathComponent }
}

@MainActor final class SubtitleArchiveStore: ObservableObject {
    @Published private(set) var sessions: [SubtitleSessionRecord] = []
    @Published private(set) var loading = false
    @Published var error: String?
    let root: URL
    var isActive: ((UUID) -> Bool)?
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RealtimeSubtitlesV1", isDirectory: true)
    }
    func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        let root = root
        do {
            let result = try await Task.detached(priority: .utility) { try SubtitleArchiveFiles.catalog(root: root) }.value
            sessions = result.records
            error = result.unreadable > 0 ? "\(result.unreadable) 个无法读取的会话已保留，未删除原文件。" : nil
        } catch { self.error = "无法读取字幕历史，原文件保留。" }
    }
    func detail(_ id: UUID) async throws -> (record: SubtitleSessionRecord, entries: [CaptionEntry], audio: [SubtitleAudioFile]) {
        let root = root
        return try await Task.detached(priority: .utility) {
            let directory = try SubtitleArchiveFiles.directory(root: root, id: id)
            return (try SubtitleSessionRecord.read(from: directory), try CaptionJournal.load(directory), try SubtitleArchiveFiles.audio(in: directory))
        }.value
    }
    func rename(_ id: UUID, title: String) async {
        guard isActive?(id) != true else { error = "请先结束本次字幕。"; return }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), root = root
        guard !title.isEmpty else { return }
        do {
            try await Task.detached(priority: .utility) {
                let directory = try SubtitleArchiveFiles.directory(root: root, id: id)
                var record = try SubtitleSessionRecord.read(from: directory)
                record.title = title; try record.write(to: directory)
            }.value
            await load()
        } catch { self.error = "会话名称未保存。" }
    }
    func delete(_ id: UUID) async {
        guard isActive?(id) != true else { error = "请先结束本次字幕并完成保存。"; return }
        let root = root
        do {
            try await Task.detached(priority: .utility) {
                let directory = try SubtitleArchiveFiles.directory(root: root, id: id)
                _ = try SubtitleSessionRecord.read(from: directory)
                try FileManager.default.removeItem(at: directory)
            }.value
            await load()
        } catch { self.error = "删除未完成，请稍后重试。" }
    }
    func export(_ id: UUID, includingAudio: Bool) async throws -> URL {
        guard isActive?(id) != true else { throw CaptionFailure.closed }
        let root = root
        return try await Task.detached(priority: .utility) { try SubtitleArchiveFiles.export(root: root, id: id, includingAudio: includingAudio) }.value
    }
}

enum SubtitleArchiveFiles {
    static func directory(root: URL, id: UUID) throws -> URL {
        let base = root.standardizedFileURL
        let rootInfo = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else { throw CaptionFailure.corruptArchive }
        let directory = base.appendingPathComponent(id.uuidString, isDirectory: true)
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true,
              directory.deletingLastPathComponent().standardizedFileURL == base else { throw CaptionFailure.corruptArchive }
        return directory
    }
    static func catalog(root: URL) throws -> (records: [SubtitleSessionRecord], unreadable: Int) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard folders.count <= 200 else { throw CaptionFailure.limit }
        var records: [SubtitleSessionRecord] = [], unreadable = 0
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do { records.append(try SubtitleSessionRecord.read(from: directory(root: root, id: id))) }
            catch { unreadable += 1 }
        }
        return (records.sorted { $0.createdAt > $1.createdAt }, unreadable)
    }
    static func audio(in directory: URL) throws -> [SubtitleAudioFile] {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        return try files.filter { $0.lastPathComponent.range(of: #"^audio-[0-9]{4}\.wav$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
                      size > 44, size <= 9_600_044 else { return nil }
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                guard let bytes = try handle.read(upToCount: 44), bytes.count == 44 else { return nil }
                func u16(_ n: Int) -> Int { Int(bytes[n]) | Int(bytes[n + 1]) << 8 }
                func u32(_ n: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[n + $1]) << ($1 * 8) } }
                guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
                      String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE",
                      u16(20) == 1, u16(22) == 1, u32(24) == 16_000, u16(34) == 16,
                      u32(40) == size - 44 else { return nil }
                return SubtitleAudioFile(url: file, duration: Double(size - 44) / 32_000)
            }
    }
    static func export(root: URL, id: UUID, includingAudio: Bool) throws -> URL {
        let directory = try directory(root: root, id: id)
        let record = try SubtitleSessionRecord.read(from: directory)
        let entries = try CaptionJournal.load(directory)
        let outputRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubtitleExports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        guard try outputRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try FileManager.default.contentsOfDirectory(atPath: outputRoot.path).count < 100 else { throw CaptionFailure.limit }
        let name = "字幕-" + String(id.uuidString.prefix(8)) + "-" + String(UUID().uuidString.prefix(8))
        let text = record.title + "\n" + record.service.name + " · " + record.language + "\n\n" + CaptionJournal.exportText(entries)
        let textURL = outputRoot.appendingPathComponent(name + ".txt")
        try Data(text.utf8).write(to: textURL, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        guard includingAudio else { return textURL }
        let zipURL = outputRoot.appendingPathComponent(name + ".zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "字幕.txt", fileURL: textURL, compressionMethod: .deflate)
        try archive.addEntry(with: "session.json", fileURL: directory.appendingPathComponent("session.json"), compressionMethod: .deflate)
        for segment in try audio(in: directory) {
            try archive.addEntry(with: segment.url.lastPathComponent, fileURL: segment.url, compressionMethod: .deflate)
        }
        return zipURL
    }
}
