import Foundation
import RayNeoArchive
import Darwin

struct PortableExportCopy: Identifiable, Sendable {
    let id: UUID
    let inTrash: Bool
    let bytes: Int64
    let modifiedAt: Date
}

struct PortableExportCatalog: Sendable {
    var copies: [PortableExportCopy] = []
    var unrecognized = 0
}

enum PortableCopyError: LocalizedError {
    case unsafe, capacity, changed
    var errorDescription: String? {
        switch self {
        case .unsafe: return "导出副本目录结构异常，未移动任何文件。"
        case .capacity: return "目标目录已达到 20 份限制；未覆盖或删除现有副本。"
        case .changed: return "副本已变化或目标已存在，请刷新后重试。"
        }
    }
}

/// Only derived ZIP export directories. Never accepts an arbitrary source path or deletes contents.
struct PortableExportCopies {
    private static let ownershipMarker = ".turboio-portable-export-v1"
    private static let markerContents = "Turbo IO portable export v1\n"
    private struct PurgePlan {
        let files: [URL]
        /// Deepest directories first. Removing an unexpected nonempty directory
        /// must fail instead of traversing and deleting its contents.
        let directories: [URL]
    }

    static func writeOwnershipMarker(to directory: URL) throws {
        try Data(markerContents.utf8).write(
            to: directory.appendingPathComponent(ownershipMarker),
            options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    }

    let parent: URL
    private var base: URL { parent.standardizedFileURL.resolvingSymlinksInPath() }
    private func root(trash: Bool) -> URL {
        base.appendingPathComponent(trash ? "PortableArchiveTrashV1" : "PortableArchiveExportsV1", isDirectory: true)
    }
    private func directory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw PortableCopyError.unsafe }
    }
    private func children(_ url: URL) throws -> [URL] {
        if !FileManager.default.fileExists(atPath: url.path) {
            // Dangling symlinks are not an absent directory.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw PortableCopyError.unsafe }
            return []
        }
        try directory(url)
        let rows = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard rows.count <= 500 else { throw PortableCopyError.unsafe }
        return rows
    }
    private func inspect(_ url: URL, id: UUID, trash: Bool) throws -> PortableExportCopy {
        try directory(url)
        var todo = [url], count = 0, bytes: Int64 = 0
        while let next = todo.popLast() {
            for child in try children(next) {
                count += 1
                guard count <= 500 else { throw PortableCopyError.unsafe }
                let value = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                guard value.isSymbolicLink != true else { throw PortableCopyError.unsafe }
                if value.isDirectory == true { todo.append(child) }
                else {
                    guard value.isRegularFile == true, let size = value.fileSize, size >= 0,
                          bytes <= Int64.max - Int64(size) else { throw PortableCopyError.unsafe }
                    bytes += Int64(size)
                }
            }
        }
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        return PortableExportCopy(id: id, inTrash: trash, bytes: bytes, modifiedAt: date)
    }
    func catalog() throws -> PortableExportCatalog {
        var catalog = PortableExportCatalog()
        for trash in [false, true] {
            for child in try children(root(trash: trash)) {
                guard let id = UUID(uuidString: child.lastPathComponent), child.lastPathComponent == id.uuidString,
                      let copy = try? inspect(child, id: id, trash: trash) else { catalog.unrecognized += 1; continue }
                catalog.copies.append(copy)
            }
        }
        catalog.copies.sort { $0.modifiedAt > $1.modifiedAt }
        return catalog
    }
    func move(_ id: UUID, toTrash: Bool) throws {
        let sourceRoot = root(trash: !toTrash), targetRoot = root(trash: toTrash)
        try directory(sourceRoot)
        let source = sourceRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        _ = try inspect(source, id: id, trash: !toTrash)
        guard try children(targetRoot).count < 20 else { throw PortableCopyError.capacity }
        if !FileManager.default.fileExists(atPath: targetRoot.path) {
            try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        try directory(targetRoot)
        let target = targetRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path),
              (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw PortableCopyError.changed }
        try FileManager.default.moveItem(at: source, to: target)
    }
    private func regularFile(_ url: URL, expectedBytes: Int64? = nil) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { return false }
        return expectedBytes.map { Int64(size) == $0 } ?? true
    }
    private func snapshotPlan(_ folder: URL, id: UUID, stage: Bool) throws -> PurgePlan? {
        try directory(folder)
        let items = try children(folder)
        let names = Set(items.map(\.lastPathComponent))
        let audio = folder.appendingPathComponent("audio", isDirectory: true)
        let notes = folder.appendingPathComponent("notes", isDirectory: true)
        let manifestURL = folder.appendingPathComponent("snapshot-manifest.json")

        // A failed stage may have been interrupted before it wrote its manifest.
        // Only empty generated subdirectories are safe to reclaim at that point.
        if stage && names.isSubset(of: ["audio", "notes"]) {
            for item in items {
                try directory(item)
                guard try children(item).isEmpty else { return nil }
            }
            return PurgePlan(files: [], directories: items + [folder])
        }
        guard names == ["audio", "notes", "snapshot-manifest.json"],
              items.count == 3 else { return nil }
        try directory(audio)
        try directory(notes)
        guard try regularFile(manifestURL),
              let count = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              count > 0, count <= 16 * 1_024 * 1_024 else { return nil }
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try? JSONDecoder().decode(ArchiveSnapshotManifest.self, from: data),
              manifest.schemaVersion == 1, manifest.snapshotID == id,
              manifest.files.count == manifest.recording.transcripts.count + 1,
              manifest.files.count <= 101,
              Set(manifest.files.map(\.relativePath)).count == manifest.files.count else { return nil }

        let recording = manifest.recording
        guard let audioEntry = manifest.files.first(where: { $0.kind == .audio }),
              manifest.files.filter({ $0.kind == .audio }).count == 1,
              audioEntry.relativePath == recording.audioRelativePath,
              audioEntry.byteCount == recording.byteCount,
              audioEntry.sha256 == recording.sha256,
              audioEntry.revisionID == nil else { return nil }
        let expectedAudio: [String: Int64] = [String(recording.audioRelativePath.dropFirst("audio/".count)): recording.byteCount]
        var expectedNotes: [String: Int64] = [:]
        for revision in recording.transcripts {
            guard let path = recording.noteRelativePath(for: revision),
                  let entry = manifest.files.first(where: { $0.relativePath == path }),
                  entry.kind == .note, entry.revisionID == revision.id,
                  entry.byteCount == revision.byteCount,
                  entry.sha256 == revision.noteSHA256 else { return nil }
            expectedNotes[String(path.dropFirst("notes/".count))] = revision.byteCount
        }
        guard expectedNotes.count == recording.transcripts.count else { return nil }
        let audioFiles = try children(audio), noteFiles = try children(notes)
        guard audioFiles.count == expectedAudio.count,
              noteFiles.count == expectedNotes.count,
              Set(audioFiles.map(\.lastPathComponent)) == Set(expectedAudio.keys),
              Set(noteFiles.map(\.lastPathComponent)) == Set(expectedNotes.keys) else { return nil }
        for file in audioFiles {
            guard let size = expectedAudio[file.lastPathComponent], try regularFile(file, expectedBytes: size) else { return nil }
        }
        for file in noteFiles {
            guard let size = expectedNotes[file.lastPathComponent], try regularFile(file, expectedBytes: size) else { return nil }
        }
        return PurgePlan(files: audioFiles + noteFiles + [manifestURL], directories: [audio, notes, folder])
    }
    private func purgePlan(_ url: URL, id: UUID) throws -> PurgePlan? {
        _ = try inspect(url, id: id, trash: true)
        let items = try children(url)
        let marker = items.first { $0.lastPathComponent == Self.ownershipMarker }
        let artifacts = items.filter { $0.lastPathComponent != Self.ownershipMarker }
        var snapshot: URL?, stage = false, archive: URL?, snapshotID: UUID?
        for artifact in artifacts {
            let name = artifact.lastPathComponent
            let parsed: UUID
            if name.hasPrefix("rayneo-snapshot-") {
                guard snapshot == nil,
                      let id = UUID(uuidString: String(name.dropFirst("rayneo-snapshot-".count))),
                      name == "rayneo-snapshot-\(id.uuidString.lowercased())" else { return nil }
                snapshot = artifact; parsed = id
            } else if name.hasPrefix(".rayneo-snapshot-"), name.hasSuffix(".staging") {
                let stem = name.dropFirst(".rayneo-snapshot-".count).dropLast(".staging".count)
                guard snapshot == nil, let id = UUID(uuidString: String(stem)),
                      name == ".rayneo-snapshot-\(id.uuidString.lowercased()).staging" else { return nil }
                snapshot = artifact; stage = true; parsed = id
            } else if name.hasPrefix("RayNeo-") {
                guard archive == nil else { return nil }
                let suffix = name.hasSuffix(".zip.partial") ? ".zip.partial" : ".zip"
                guard name.hasSuffix(suffix),
                      let id = UUID(uuidString: String(name.dropFirst("RayNeo-".count).dropLast(suffix.count))),
                      name == "RayNeo-\(id.uuidString.lowercased())\(suffix)",
                      try regularFile(artifact) else { return nil }
                archive = artifact; parsed = id
            } else { return nil }
            guard snapshotID == nil || snapshotID == parsed else { return nil }
            snapshotID = parsed
        }
        if let marker {
            guard try regularFile(marker, expectedBytes: Int64(Self.markerContents.utf8.count)),
                  try Data(contentsOf: marker) == Data(Self.markerContents.utf8) else { return nil }
        } else {
            // Older complete exports lacked a marker; a valid published snapshot
            // provides the required ownership evidence.
            guard snapshot != nil, !stage else { return nil }
        }
        guard archive == nil || (snapshot != nil && !stage) else { return nil }
        var plan = PurgePlan(files: [], directories: [])
        if let snapshot, let snapshotID {
            guard let validated = try snapshotPlan(snapshot, id: snapshotID, stage: stage) else { return nil }
            plan = validated
        }
        return PurgePlan(files: plan.files + [archive, marker].compactMap { $0 },
                         directories: plan.directories + [url])
    }
    func purgeableTrashCopies() throws -> [PortableExportCopy] {
        try catalog().copies.filter { copy in
            guard copy.inTrash else { return false }
            let url = root(trash: true).appendingPathComponent(copy.id.uuidString, isDirectory: true)
            return (try? purgePlan(url, id: copy.id)) != nil
        }
    }
    /// Permanently removes only recognized, inspected copies already in the
    /// recoverable trash. Unknown entries are left untouched for manual review.
    func purgeTrash() throws -> Int64 {
        var removed: Int64 = 0
        for copy in try purgeableTrashCopies() {
            let child = root(trash: true).appendingPathComponent(copy.id.uuidString, isDirectory: true)
            guard let plan = try purgePlan(child, id: copy.id) else { continue }
            for file in plan.files {
                guard Darwin.unlink(file.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            for directory in plan.directories {
                guard Darwin.rmdir(directory.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            removed += copy.bytes
        }
        return removed
    }
}
