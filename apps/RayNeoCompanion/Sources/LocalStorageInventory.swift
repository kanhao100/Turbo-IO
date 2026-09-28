import Foundation
import Combine
import RayNeoCaptions
import RayNeoArchive

/// Logical file sizes for the app's named local directories. System storage may
/// also include databases, URL caches, file-system overhead, and model assets.
struct StorageCategory: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case verifiedRecordings, importedRecordings, subtitleSessions, alwaysOnTranscripts
        case books, conversationTimeline, recordingInbox, portableExports, portableTrash
        case recoveryExports, teleprompterOutbox, manualASRDiagnostics, alwaysOnProbe
        case subtitleExports, alwaysOnExports, localTranscriptionExperiments, archiveStaging

        var id: Self { self }
        var title: String {
            switch self {
            case .verifiedRecordings: return "已校验录音归档"
            case .importedRecordings: return "旧版导入录音"
            case .subtitleSessions: return "实时字幕会话"
            case .alwaysOnTranscripts: return "全天智记文字"
            case .books: return "本地书库"
            case .conversationTimeline: return "对话时间轴"
            case .recordingInbox: return "眼镜录音接收箱"
            case .portableExports: return "便携归档副本"
            case .portableTrash: return "便携副本暂存箱"
            case .recoveryExports: return "录音恢复副本"
            case .teleprompterOutbox: return "提词稿发送箱"
            case .manualASRDiagnostics: return "手动识别诊断"
            case .alwaysOnProbe: return "旧版全天智记诊断"
            case .subtitleExports: return "字幕分享缓存"
            case .alwaysOnExports: return "智记分享缓存"
            case .localTranscriptionExperiments: return "本地识别临时文件"
            case .archiveStaging: return "归档导入临时文件"
            }
        }
        var isCache: Bool {
            switch self {
            case .subtitleExports, .alwaysOnExports, .localTranscriptionExperiments, .archiveStaging: return true
            default: return false
            }
        }
        var description: String {
            switch self {
            case .subtitleExports, .alwaysOnExports:
                return "仅清理一小时前生成的分享文件；近期副本保留供分享。"
            case .localTranscriptionExperiments, .archiveStaging:
                return "处理任务可能仍在使用，需由任务自身清理。"
            case .portableTrash:
                return "可恢复；清理将永久删除已识别的暂存副本，异常文件保留。"
            case .verifiedRecordings:
                return "含音频、笔记与校验记录；当前归档没有逐条删除接口。"
            case .subtitleSessions:
                return "可删除已结束会话，或只清除其已保存音频。"
            case .alwaysOnTranscripts:
                return "全天智记文字；写入与删除尚未建立统一锁，存储页只展示占用。"
            default:
                return "本机个人资料；存储页面仅查看。"
            }
        }
    }

    let kind: Kind
    let title: String
    let bytes: Int64
    let fileCount: Int
    let description: String
    let isCache: Bool
    let canClear: Bool
    /// The amount the named cache action can remove at the time of this scan.
    let clearableBytes: Int64
    var id: Kind { kind }
}

struct StorageRecord: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case subtitle(UUID)
        case alwaysOnDay(String)
        case other(StorageCategory.Kind, String)
    }

    let id: ID
    let title: String
    let date: Date
    let bytes: Int64
    let category: StorageCategory.Kind
    let canDelete: Bool
    /// Actual WAV file bytes on disk. Nil outside subtitle sessions.
    let audioBytes: Int64?
}

enum StorageInventoryError: LocalizedError {
    case unsupported, busy, stale, unsafe, incomplete

    var errorDescription: String? {
        switch self {
        case .unsupported: return "此类文件目前只能查看，不能从存储页面删除。"
        case .busy: return "相关会话或文件任务仍在进行，请先结束后重试。"
        case .stale: return "记录已变化，请刷新存储列表后重试。"
        case .unsafe: return "目录或文件结构异常，已停止清理。"
        case .incomplete: return "清理未完成，请刷新后核对剩余文件。"
        }
    }
}

@MainActor final class LocalStorageInventory: ObservableObject {
    @Published private(set) var categories: [StorageCategory] = []
    @Published private(set) var records: [StorageRecord] = []
    @Published private(set) var scanning = false
    @Published private(set) var error: String?
    @Published private(set) var lastScannedAt: Date?
    @Published private(set) var notice: String?

    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    var reclaimableCacheBytes: Int64 { categories.filter { $0.isCache }.reduce(0) { $0 + $1.clearableBytes } }

    private let store: CompanionStore
    init(store: CompanionStore) { self.store = store }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        await store.subtitleArchive.load()
        await store.alwaysOnArchive.load()
        await store.books.load()
        await store.archive.load()

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let archiveParent = store.archive.rootDirectory.deletingLastPathComponent()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let temporary = FileManager.default.temporaryDirectory
        let roots: [StorageDiskScanner.Root] = StorageCategory.Kind.allCases.map { kind in
            let url: URL
            switch kind {
            case .subtitleSessions: url = store.subtitleArchive.root
            case .alwaysOnTranscripts: url = store.alwaysOnArchive.root
            case .subtitleExports: url = caches.appendingPathComponent("SubtitleExports", isDirectory: true)
            case .alwaysOnExports: url = caches.appendingPathComponent("AlwaysOnExports", isDirectory: true)
            case .localTranscriptionExperiments:
                url = temporary.appendingPathComponent("LocalAudioTranscriptionExperimentV1", isDirectory: true)
            case .archiveStaging: url = temporary
            case .verifiedRecordings:
                url = store.archive.rootDirectory
            case .manualASRDiagnostics:
                url = documents.appendingPathComponent("ManualASRDiagnosticsV1", isDirectory: true)
            default:
                let name: String
                switch kind {
                case .importedRecordings: name = "ImportedRecordings"
                case .books: name = "ReadingLibraryV1"
                case .conversationTimeline: name = "ConversationTimelineV1"
                case .recordingInbox: name = "GlassesRecordingInboxV1"
                case .portableExports: name = "PortableArchiveExportsV1"
                case .portableTrash: name = "PortableArchiveTrashV1"
                case .recoveryExports: name = "RecordingRecoveryExportsV1"
                case .teleprompterOutbox: name = "TeleprompterOutboxV1"
                case .alwaysOnProbe: name = "AlwaysOnLocalProbeV1"
                default: name = ""
                }
                url = archiveParent.appendingPathComponent(name, isDirectory: true)
            }
            return .init(kind: kind, url: url)
        }
        var seeds: [StorageDiskScanner.Seed] = []
        for session in store.subtitleArchive.sessions {
            seeds.append(.init(id: .subtitle(session.id), category: .subtitleSessions,
                title: session.title, date: session.createdAt,
                urls: [store.subtitleArchive.root.appendingPathComponent(session.id.uuidString, isDirectory: true)],
                canDelete: session.state != .active && store.subtitleArchive.isActive?(session.id) != true))
        }
        for day in store.alwaysOnArchive.days {
            seeds.append(.init(id: .alwaysOnDay(day.day), category: .alwaysOnTranscripts,
                title: day.day, date: day.updatedAt,
                urls: [store.alwaysOnArchive.root.appendingPathComponent(day.day, isDirectory: true)],
                canDelete: false))
        }
        for book in store.books.books {
            seeds.append(.init(id: .other(.books, book.id.uuidString), category: .books,
                title: book.title, date: book.importedAt,
                urls: [archiveParent.appendingPathComponent("ReadingLibraryV1", isDirectory: true)
                    .appendingPathComponent(book.id.uuidString + ".json")], canDelete: false))
        }
        for recording in store.archive.recordings {
            let urls = [store.archive.rootDirectory.appendingPathComponent(recording.audioRelativePath)] +
                recording.transcripts.compactMap { recording.noteRelativePath(for: $0) }
                    .map { store.archive.rootDirectory.appendingPathComponent($0) }
            seeds.append(.init(id: .other(.verifiedRecordings, recording.id.uuidString),
                category: .verifiedRecordings, title: recording.title, date: recording.importedAt,
                urls: urls, canDelete: false))
        }
        var missingLegacyRecordings = 0
        for recording in store.recordings {
            let file = store.recordingURL(recording)
            if file == nil { missingLegacyRecordings += 1 }
            seeds.append(.init(id: .other(.importedRecordings, recording.id.uuidString),
                category: .importedRecordings, title: recording.name, date: recording.importedAt,
                urls: file.map { [$0] } ?? [], canDelete: false))
        }

        let subtitleClearAllowed = !store.realtimeSubtitles.active && !store.realtimeSubtitles.saving && !store.subtitleArchive.loading
        let alwaysOnClearAllowed = !store.alwaysOn.occupied && !store.alwaysOnArchive.loading
        let trashClearAllowed = !store.archive.isBusy
        let snapshot = await Task.detached(priority: .utility) {
            StorageDiskScanner.scan(roots: roots, seeds: seeds, documents: archiveParent, caches: caches,
                subtitleClearAllowed: subtitleClearAllowed,
                alwaysOnClearAllowed: alwaysOnClearAllowed,
                trashClearAllowed: trashClearAllowed, now: Date())
        }.value
        categories = snapshot.categories
        records = snapshot.records
        lastScannedAt = Date()
        let scope = "仅统计 Turbo IO 已知目录的文件字节，逐条列表只显示已识别记录；系统显示的 App 占用可能不同。"
        let issues = snapshot.issues + (missingLegacyRecordings > 0
            ? ["\(missingLegacyRecordings) 条旧版录音登记的文件未找到，已按 0 字节计入。"] : [])
        notice = issues.isEmpty ? scope : scope + " " + issues.joined(separator: " ")
        error = issues.isEmpty ? nil : "部分文件未能完整读取，原文件已保留。"
    }

    /// Named share caches remove only old regular files. Portable archive trash
    /// uses the archive controller's validated permanent-delete operation.
    func clearCache(_ kind: StorageCategory.Kind) async throws {
        guard kind == .subtitleExports || kind == .alwaysOnExports || kind == .portableTrash else {
            throw StorageInventoryError.unsupported
        }
        guard !scanning else { throw StorageInventoryError.busy }
        if kind == .portableTrash {
            guard !store.archive.isBusy else { throw StorageInventoryError.busy }
            do { _ = try await store.archive.purgeExportTrash() }
            catch { await refresh(); throw error }
            await refresh()
            return
        }
        if kind == .subtitleExports {
            guard !store.realtimeSubtitles.active && !store.realtimeSubtitles.saving && !store.subtitleArchive.loading else { throw StorageInventoryError.busy }
        } else {
            guard !store.alwaysOn.occupied && !store.alwaysOnArchive.loading else { throw StorageInventoryError.busy }
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        do {
            try await Task.detached(priority: .utility) {
                try StorageDiskScanner.clearCache(kind: kind, caches: caches, now: Date())
            }.value
        } catch {
            await refresh()
            throw error
        }
        await refresh()
    }

    func delete(_ record: StorageRecord) async throws {
        guard !scanning else { throw StorageInventoryError.busy }
        guard records.contains(where: { $0.id == record.id && $0.category == record.category && $0.canDelete }) else {
            throw StorageInventoryError.stale
        }
        switch record.id {
        case .subtitle(let id):
            guard record.category == .subtitleSessions, store.subtitleArchive.isActive?(id) != true else {
                throw StorageInventoryError.busy
            }
            let directory = try SubtitleArchiveFiles.directory(root: store.subtitleArchive.root, id: id)
            let session = try SubtitleSessionRecord.read(from: directory)
            guard session.state != .active else { throw StorageInventoryError.busy }
            store.subtitlePlayback.stop()
            await store.subtitleArchive.delete(id)
            guard !StorageDiskScanner.itemStillPresent(directory) else {
                await refresh(); throw StorageInventoryError.incomplete
            }
        case .alwaysOnDay:
            throw StorageInventoryError.unsupported
        case .other:
            throw StorageInventoryError.unsupported
        }
        await refresh()
    }

    /// The subtitle store validates the session and removes only its WAV segments.
    @discardableResult func purgeSubtitleAudio(_ id: UUID) async throws -> Int64 {
        guard !scanning else { throw StorageInventoryError.busy }
        guard records.contains(where: { $0.id == .subtitle(id) && ($0.audioBytes ?? 0) > 0 }) else {
            throw StorageInventoryError.stale
        }
        guard store.subtitleArchive.isActive?(id) != true else { throw StorageInventoryError.busy }
        store.subtitlePlayback.stop()
        do {
            let freed = try await store.subtitleArchive.purgeAudio(id)
            await refresh()
            return freed
        } catch {
            await refresh()
            throw error
        }
    }
}

private enum StorageDiskScanner {
    struct Root: Sendable { let kind: StorageCategory.Kind; let url: URL }
    struct Seed: Sendable {
        let id: StorageRecord.ID
        let category: StorageCategory.Kind
        let title: String
        let date: Date
        let urls: [URL]
        let canDelete: Bool
    }
    struct Snapshot: Sendable {
        let categories: [StorageCategory]
        let records: [StorageRecord]
        let issues: [String]
    }
    private struct Size {
        var bytes: Int64 = 0
        var files = 0
        var exists = false
        var skipped = 0
        mutating func add(_ other: Size) throws {
            let (sum, overflow) = bytes.addingReportingOverflow(other.bytes)
            guard !overflow else { throw StorageInventoryError.unsafe }
            bytes = sum; files += other.files; skipped += other.skipped
            exists = exists || other.exists
        }
    }

    static func itemStillPresent(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) ||
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func scan(roots: [Root], seeds: [Seed], documents: URL, caches: URL,
                     subtitleClearAllowed: Bool, alwaysOnClearAllowed: Bool,
                     trashClearAllowed: Bool, now: Date) -> Snapshot {
        var categories: [StorageCategory] = [], records: [StorageRecord] = [], issues: [String] = []
        let paths = roots.filter { $0.kind != .archiveStaging }.map { $0.url.standardizedFileURL.path }
        var seen = Set<String>()
        for root in roots {
            var amount = Size(), clearable: Int64 = 0
            let path = root.url.standardizedFileURL.path
            do {
                if root.kind == .archiveStaging {
                    amount = try stagingSize(temporary: root.url)
                } else if seen.insert(path).inserted {
                    let excluded = Set(paths.filter { $0 != path && $0.hasPrefix(path + "/") })
                    amount = try size(root.url, excluding: excluded)
                } else {
                    issues.append("\(root.kind.title)与其他类别使用同一目录，已避免重复计数。")
                }
                let permitted = root.kind == .subtitleExports ? subtitleClearAllowed : alwaysOnClearAllowed
                if permitted && (root.kind == .subtitleExports || root.kind == .alwaysOnExports) {
                    clearable = try eligibleCacheFiles(kind: root.kind, caches: caches, now: now)
                        .reduce(Int64(0)) { $0 + $1.bytes }
                } else if root.kind == .portableTrash && trashClearAllowed {
                    clearable = try PortableExportCopies(parent: documents).purgeableTrashCopies()
                        .reduce(Int64(0)) { $0 + $1.bytes }
                }
                if amount.skipped > 0 { issues.append("\(root.kind.title)跳过了 \(amount.skipped) 个非普通文件。") }
            } catch {
                issues.append("\(root.kind.title)未能完整读取。")
            }
            categories.append(StorageCategory(kind: root.kind, title: root.kind.title,
                bytes: amount.bytes, fileCount: amount.files,
                description: root.kind.description, isCache: root.kind.isCache,
                canClear: clearable > 0, clearableBytes: clearable))
        }
        for seed in seeds {
            var amount = Size(), audio: Int64? = nil
            do {
                for url in seed.urls {
                    let part = try size(url)
                    if !part.exists { issues.append("\(seed.title)有登记文件未找到，已按实际文件计数。") }
                    try amount.add(part)
                }
                if seed.category == .subtitleSessions, let directory = seed.urls.first {
                    audio = try subtitleAudioBytes(in: directory)
                }
            } catch {
                issues.append("\(seed.title)的大小未能完整读取。")
            }
            records.append(StorageRecord(id: seed.id, title: seed.title, date: seed.date,
                bytes: amount.bytes, category: seed.category,
                canDelete: seed.canDelete && amount.exists && amount.skipped == 0,
                audioBytes: audio))
        }
        do {
            let copies = try PortableExportCopies(parent: documents).catalog().copies
            for copy in copies {
                records.append(StorageRecord(id: .other(copy.inTrash ? .portableTrash : .portableExports,
                    copy.id.uuidString), title: "便携归档 \(copy.id.uuidString.prefix(8))",
                    date: copy.modifiedAt, bytes: copy.bytes,
                    category: copy.inTrash ? .portableTrash : .portableExports,
                    canDelete: false, audioBytes: nil))
            }
        } catch { issues.append("便携归档副本列表未能读取。") }
        do {
            let inboxRoot = documents.appendingPathComponent("GlassesRecordingInboxV1", isDirectory: true)
            for entry in try GlassesRecordingInbox(root: inboxRoot).catalog().entries {
                let folder = inboxRoot.appendingPathComponent(entry.id, isDirectory: true)
                let amount = try size(folder)
                records.append(StorageRecord(id: .other(.recordingInbox, entry.id),
                    title: "眼镜录音 \(entry.id.prefix(8))", date: entry.createdAt,
                    bytes: amount.bytes, category: .recordingInbox,
                    canDelete: false, audioBytes: nil))
            }
        } catch { issues.append("眼镜录音接收列表未能完整读取。") }
        records.sort { $0.bytes == $1.bytes ? $0.date > $1.date : $0.bytes > $1.bytes }
        return Snapshot(categories: categories, records: records, issues: issues)
    }

    private static func size(_ root: URL, excluding excluded: Set<String> = []) throws -> Size {
        guard FileManager.default.fileExists(atPath: root.path) else {
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw StorageInventoryError.unsafe
            }
            return Size()
        }
        var result = Size(), pending = [root], visited = 0
        while let url = pending.popLast() {
            if excluded.contains(url.standardizedFileURL.path) { continue }
            visited += 1
            guard visited <= 100_000 else { throw StorageInventoryError.unsafe }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { result.skipped += 1; continue }
            if values.isDirectory == true {
                result.exists = true
                pending.append(contentsOf: try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]))
            } else if values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 {
                let (sum, overflow) = result.bytes.addingReportingOverflow(Int64(fileSize))
                guard !overflow else { throw StorageInventoryError.unsafe }
                result.bytes = sum; result.files += 1; result.exists = true
            } else { result.skipped += 1 }
        }
        return result
    }

    private static func stagingSize(temporary: URL) throws -> Size {
        let values = try temporary.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageInventoryError.unsafe }
        var total = Size()
        for child in try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
            let name = child.lastPathComponent, prefix = "companion-archive-incoming-"
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try total.add(size(child))
        }
        return total
    }

    private static func subtitleAudioBytes(in directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        var total: Int64 = 0
        for file in files where file.lastPathComponent.range(of: #"^audio-[0-9]{4}\.wav$"#,
                                                              options: .regularExpression) != nil {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes >= 0 else { throw StorageInventoryError.unsafe }
            let (sum, overflow) = total.addingReportingOverflow(Int64(bytes))
            guard !overflow else { throw StorageInventoryError.unsafe }
            total = sum
        }
        return total
    }

    private struct CacheFile { let url: URL; let bytes: Int64 }
    private static func eligibleCacheFiles(kind: StorageCategory.Kind, caches: URL, now: Date) throws -> [CacheFile] {
        let name = kind == .subtitleExports ? "SubtitleExports" : "AlwaysOnExports"
        guard kind == .subtitleExports || kind == .alwaysOnExports else { throw StorageInventoryError.unsupported }
        let base = caches.standardizedFileURL
        let root = base.appendingPathComponent(name, isDirectory: true)
        guard root.deletingLastPathComponent().standardizedFileURL == base else { throw StorageInventoryError.unsafe }
        let baseInfo = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard baseInfo.isDirectory == true, baseInfo.isSymbolicLink != true else { throw StorageInventoryError.unsafe }
        guard FileManager.default.fileExists(atPath: root.path) else {
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw StorageInventoryError.unsafe
            }
            return []
        }
        let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else { throw StorageInventoryError.unsafe }
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentModificationDateKey])
        guard files.count <= 1_000 else { throw StorageInventoryError.unsafe }
        let pattern = kind == .subtitleExports
            ? #"^字幕-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{8}\.(txt|zip)$"#
            : #"^全天智记-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9A-Fa-f]{8}\.(txt|zip)$"#
        return try files.compactMap { file in
            guard file.deletingLastPathComponent().standardizedFileURL == root,
                  file.lastPathComponent.range(of: pattern, options: .regularExpression) != nil else { return nil }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes >= 0,
                  let modified = values.contentModificationDate,
                  modified <= now.addingTimeInterval(-3_600) else { return nil }
            return CacheFile(url: file, bytes: Int64(bytes))
        }
    }

    static func clearCache(kind: StorageCategory.Kind, caches: URL, now: Date) throws {
        let files = try eligibleCacheFiles(kind: kind, caches: caches, now: now)
        for file in files {
            // Re-evaluate before each removal; an export may have refreshed it.
            guard try eligibleCacheFiles(kind: kind, caches: caches, now: now)
                .contains(where: { $0.url == file.url && $0.bytes == file.bytes }) else { continue }
            try FileManager.default.removeItem(at: file.url)
        }
    }
}
