import Foundation
import Combine
import ZIPFoundation
import RayNeoCaptions

struct AlwaysOnSettings: Codable, Equatable, Sendable {
    var enabled = false
    var targetDeviceID: String?
    var showOnGlasses = true
    var languageMode: RecognitionLanguageMode = .automatic
}

enum AlwaysOnApplyPolicy { case immediately, nextTask, cancel }

enum AlwaysOnTranscriptKind: String, Codable, CaseIterable, Sendable {
    case started, final, unfinished, gap, stopped, system
}

struct AlwaysOnTranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var runID: UUID
    var kind: AlwaysOnTranscriptKind
    var text: String
    var service: String
    var model: String
    var languageMode: RecognitionLanguageMode
    var detectedLanguage: String?
}

struct AlwaysOnDaySummary: Codable, Identifiable, Equatable, Sendable {
    var day: String
    var entryCount: Int
    var finalCount: Int
    var gapCount: Int
    var updatedAt: Date
    var id: String { day }
}

private struct AlwaysOnDayManifest: Codable {
    var schemaVersion = 1
    var day: String
    var createdAt: Date
    var updatedAt: Date
}

enum AlwaysOnArchiveError: Error { case invalidDay, invalidEntry, corruptArchive, limit }

/// Append-only, text-only daily archive. Every run gets a new JSONL segment so
/// a process interruption can damage at most one final line.
@MainActor final class AlwaysOnTranscriptArchive: ObservableObject {
    @Published private(set) var days: [AlwaysOnDaySummary] = []
    @Published private(set) var loading = false
    @Published var error: String?
    let root: URL
    private let calendar: Calendar
    private let timeZone: TimeZone

    init(root: URL? = nil, calendar: Calendar = .autoupdatingCurrent,
         timeZone: TimeZone = .autoupdatingCurrent) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlwaysOnTranscriptsV1", isDirectory: true)
        self.calendar = calendar; self.timeZone = timeZone
    }

    func dayKey(for date: Date) -> String {
        var calendar = calendar; calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func append(_ entry: AlwaysOnTranscriptEntry) throws {
        guard entry.text.utf8.count <= 32_768,
              !entry.text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw AlwaysOnArchiveError.invalidEntry }
        let day = dayKey(for: entry.timestamp)
        let directory = try dayDirectory(day, create: true)
        try ensureManifest(day: day, directory: directory, date: entry.timestamp)
        let file = directory.appendingPathComponent("entries-\(entry.runID.uuidString.lowercased()).jsonl")
        let line = try encoder.encode(entry) + Data([0x0a])
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                throw AlwaysOnArchiveError.corruptArchive
            }
        }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              (info.fileSize ?? 0) + line.count <= 32 * 1_024 * 1_024 else { throw AlwaysOnArchiveError.limit }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.synchronize()
    }

    func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        let root = root
        do {
            days = try await Task.detached(priority: .utility) {
                try Self.catalog(root: root)
            }.value
            error = nil
        } catch { self.error = "无法读取全天智记历史；原文字文件仍保留。" }
    }

    func entries(for day: String) async throws -> [AlwaysOnTranscriptEntry] {
        let root = root
        return try await Task.detached(priority: .utility) { try Self.readEntries(root: root, day: day) }.value
    }

    func delete(day: String) async {
        let root = root
        do {
            try await Task.detached(priority: .utility) {
                let directory = try Self.checkedDayDirectory(root: root, day: day)
                try FileManager.default.removeItem(at: directory)
            }.value
            await load()
        } catch { self.error = "删除没有完成；原记录可能仍在。" }
    }

    func exportText(day: String) async throws -> URL {
        let root = root
        return try await Task.detached(priority: .utility) {
            let entries = try Self.readEntries(root: root, day: day)
            let output = try Self.exportDirectory().appendingPathComponent("全天智记-\(day)-\(UUID().uuidString.prefix(8)).txt")
            let body = entries.compactMap { entry -> String? in
                switch entry.kind {
                case .final, .unfinished: return "[\(entry.timestamp.formatted(date: .omitted, time: .standard))] \(entry.text)"
                case .gap, .system: return "[\(entry.timestamp.formatted(date: .omitted, time: .standard))] 【\(entry.text)】"
                case .started, .stopped: return nil
                }
            }.joined(separator: "\n")
            try Data(("全天智记 · \(day)\n\n" + body + "\n").utf8).write(to: output,
                options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            return output
        }.value
    }

    func exportZIP(day: String) async throws -> URL {
        let root = root
        return try await Task.detached(priority: .utility) {
            let directory = try Self.checkedDayDirectory(root: root, day: day)
            let output = try Self.exportDirectory().appendingPathComponent("全天智记-\(day)-\(UUID().uuidString.prefix(8)).zip")
            let zip = try Archive(url: output, accessMode: .create)
            for file in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      file.lastPathComponent == "day.json" || file.lastPathComponent.hasSuffix(".jsonl") else { continue }
                try zip.addEntry(with: file.lastPathComponent, fileURL: file, compressionMethod: .deflate)
            }
            return output
        }.value
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]
        return value
    }

    private func dayDirectory(_ day: String, create: Bool) throws -> URL {
        guard Self.validDay(day) else { throw AlwaysOnArchiveError.invalidDay }
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var rootURL = root, values = URLResourceValues(); values.isExcludedFromBackup = true
            try rootURL.setResourceValues(values)
            let directory = root.appendingPathComponent(day, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            return directory
        }
        return try Self.checkedDayDirectory(root: root, day: day)
    }

    private func ensureManifest(day: String, directory: URL, date: Date) throws {
        let file = directory.appendingPathComponent("day.json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let manifest = AlwaysOnDayManifest(day: day, createdAt: date, updatedAt: date)
        try encoder.encode(manifest).write(to: file,
            options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated private static func validDay(_ day: String) -> Bool {
        day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
    }

    nonisolated private static func checkedDayDirectory(root: URL, day: String) throws -> URL {
        guard validDay(day) else { throw AlwaysOnArchiveError.invalidDay }
        let base = root.standardizedFileURL, directory = base.appendingPathComponent(day, isDirectory: true)
        guard directory.deletingLastPathComponent().standardizedFileURL == base else { throw AlwaysOnArchiveError.invalidDay }
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw AlwaysOnArchiveError.corruptArchive }
        return directory
    }

    nonisolated private static func readEntries(root: URL, day: String) throws -> [AlwaysOnTranscriptEntry] {
        let directory = try checkedDayDirectory(root: root, day: day)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("entries-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 512 else { throw AlwaysOnArchiveError.limit }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var result: [AlwaysOnTranscriptEntry] = []
        for file in files {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 32 * 1_024 * 1_024 else {
                throw AlwaysOnArchiveError.corruptArchive
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let lines = data.split(separator: 0x0a)
            for (index, line) in lines.enumerated() {
                // Ignore one torn final line after a crash, but never hide corruption in
                // a completed earlier line.
                do { result.append(try decoder.decode(AlwaysOnTranscriptEntry.self, from: Data(line))) }
                catch {
                    if index == lines.count - 1, data.last != 0x0a { continue }
                    throw AlwaysOnArchiveError.corruptArchive
                }
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    nonisolated private static func catalog(root: URL) throws -> [AlwaysOnDaySummary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else { throw AlwaysOnArchiveError.corruptArchive }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { validDay($0.lastPathComponent) }
        guard folders.count <= 3_650 else { throw AlwaysOnArchiveError.limit }
        return try folders.map { folder in
            let entries = try readEntries(root: root, day: folder.lastPathComponent)
            return AlwaysOnDaySummary(day: folder.lastPathComponent, entryCount: entries.count,
                finalCount: entries.filter { $0.kind == .final }.count,
                gapCount: entries.filter { $0.kind == .gap }.count,
                updatedAt: entries.last?.timestamp ?? .distantPast)
        }.sorted { $0.day > $1.day }
    }

    nonisolated private static func exportDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlwaysOnExports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).count < 100 else { throw AlwaysOnArchiveError.limit }
        return root
    }
}
