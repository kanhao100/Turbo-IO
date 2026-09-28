import Foundation

enum TransactionCheckpoint: Sendable { case sourceChunkCopied, journalDurable, filePublished, manifestPublished, fileRemoved }

/// A local, source-preserving archive. It does not contact glasses, decode audio, recognize speech, or upload.
/// The host must keep security-scoped URLs accessible for the duration of each call.
public actor ArchiveStore {
    private let files: ArchiveFileSystem
    private let limits: ArchiveLimits
    private let checkpoint: (@Sendable (TransactionCheckpoint) throws -> Void)?

    /// `rootDirectory` must already exist and be a dedicated directory explicitly chosen by the host.
    public init(rootDirectory: URL, limits: ArchiveLimits = ArchiveLimits()) throws {
        try limits.validate()
        self.limits = limits
        self.files = try ArchiveFileSystem(rootDirectory: rootDirectory)
        self.checkpoint = nil
    }

    // Tests can stop after a durable transaction boundary. This is not a public production API.
    init(rootDirectory: URL, limits: ArchiveLimits = ArchiveLimits(), checkpoint: @escaping @Sendable (TransactionCheckpoint) throws -> Void) throws {
        try limits.validate()
        self.limits = limits
        self.files = try ArchiveFileSystem(rootDirectory: rootDirectory)
        self.checkpoint = checkpoint
    }

    /// Copy one explicitly selected regular file. Content-identical reimports keep the original ID/title/date.
    public func importFile(at source: URL, title: String, recordedAt: Date? = nil) throws -> ArchiveReceipt {
        let title = try validatedTitle(title)
        return try files.locked {
            var manifest = try loadAndRecover().manifest
            let transactionID = UUID()
            let stem = transactionID.uuidString.lowercased()
            let stageName = stem + ".blob"
            var journalPrepared = false
            do {
                let copied = try files.copySource(source, stageName: stageName, limit: limits.maximumFileBytes) {
                    try self.checkpoint?(.sourceChunkCopied)
                }
                guard try files.verify(in: files.staging.value, name: stageName, sha256: copied.sha256,
                                       size: copied.byteCount, limit: limits.maximumFileBytes) else {
                    throw ArchiveError.missingRecoveryData
                }
                if let existing = manifest.recordings.first(where: { $0.sha256 == copied.sha256 }) {
                    guard existing.byteCount == copied.byteCount else { throw ArchiveError.invalidManifest }
                    try verifyAudio(existing)
                    try files.removeStageIfPresent(stageName)
                    return try receipt(existing, reused: true)
                }
                guard manifest.recordings.count < limits.maximumRecordings else { throw ArchiveError.recordingLimitExceeded }
                let date = Date()
                let ext = source.pathExtension.lowercased()
                let recording = ArchivedRecording(
                    id: UUID(), title: title, importedAt: date, recordedAt: recordedAt,
                    sha256: copied.sha256, byteCount: copied.byteCount,
                    fileExtension: supportedExtensions.contains(ext) ? ext : "bin",
                    checksumVerifiedAt: date, transcripts: []
                )
                let mutation = Mutation.imported(recording)
                try apply(mutation, to: &manifest)
                let manifestData = try encodeManifest(manifest)
                try commit(mutation, transactionID: transactionID, manifestData: manifestData, prepared: &journalPrepared)
                return try receipt(recording, reused: false)
            } catch {
                if !journalPrepared { cleanupUnprepared(stem) }
                throw error
            }
        }
    }

    /// Export host-provided text as a new immutable Markdown revision. Identical input is idempotent.
    /// A title or text change creates another note; existing notes are never overwritten.
    public func exportTranscript(for recordingID: UUID, text: String, title: String? = nil) throws -> NoteReceipt {
        let text = try normalizedTranscript(text, limit: limits.maximumTranscriptBytes)
        return try files.locked {
            var manifest = try loadAndRecover().manifest
            guard let index = manifest.recordings.firstIndex(where: { $0.id == recordingID }) else {
                throw ArchiveError.recordingNotFound
            }
            var recording = manifest.recordings[index]
            try verifyAudio(recording)
            let title = try validatedTitle(title ?? recording.title)
            let inputDigest = try transcriptInputDigest(title: title, text: text)
            if let existing = recording.transcripts.first(where: { $0.inputSHA256 == inputDigest }) {
                try verifyNote(existing, recordingID: recordingID)
                return try noteReceipt(recording, revision: existing, reused: true)
            }
            guard recording.transcripts.count < limits.maximumRevisionsPerRecording else { throw ArchiveError.revisionLimitExceeded }
            let date = Date()
            let number = recording.transcripts.count + 1
            let note = try markdownNote(recording: recording, revision: number, title: title, text: text, date: date)
            let revision = TranscriptRevision(id: UUID(), number: number, title: title, createdAt: date,
                                              inputSHA256: inputDigest, noteSHA256: digest(note), byteCount: Int64(note.count))
            let transactionID = UUID()
            let stem = transactionID.uuidString.lowercased()
            var journalPrepared = false
            do {
                try files.writeExclusive(note, name: stem + ".blob")
                guard try files.verify(in: files.staging.value, name: stem + ".blob", sha256: revision.noteSHA256,
                                       size: revision.byteCount, limit: maximumNoteBytes) else { throw ArchiveError.missingRecoveryData }
                let mutation = Mutation.transcript(recordingID: recordingID, revision: revision)
                try apply(mutation, to: &manifest)
                let manifestData = try encodeManifest(manifest)
                try commit(mutation, transactionID: transactionID, manifestData: manifestData, prepared: &journalPrepared)
                recording = manifest.recordings[index]
                return try noteReceipt(recording, revision: revision, reused: false)
            } catch {
                if !journalPrepared { cleanupUnprepared(stem) }
                throw error
            }
        }
    }

    /// Metadata only after transaction recovery. `checksumVerifiedAt` is historical; call verifyRecording for a fresh check.
    public func listRecordings() throws -> [ArchivedRecording] {
        try files.locked { try loadAndRecover().manifest.recordings }
    }

    public func verifyRecording(_ id: UUID) throws -> ArchiveReceipt {
        try files.locked {
            guard let recording = try loadAndRecover().manifest.recordings.first(where: { $0.id == id }) else {
                throw ArchiveError.recordingNotFound
            }
            try verifyAudio(recording)
            return try receipt(recording, reused: true)
        }
    }

    /// Remove one whole archived recording and its registered Markdown revisions.
    /// The original imported source and separately exported snapshots are never touched.
    /// Once the delete journal is durable, `recover()` resumes cleanup if the remaining files still match.
    public func deleteRecording(_ id: UUID) throws -> ArchiveDeletionReceipt {
        try files.locked {
            var manifest = try loadAndRecover().manifest
            guard let recording = manifest.recordings.first(where: { $0.id == id }) else {
                throw ArchiveError.recordingNotFound
            }
            try verifyDeletionContents(recording)
            let beforeData = try encodeManifest(manifest)
            let mutation = Mutation.deleted(recording)
            try apply(mutation, to: &manifest)
            let afterData = try encodeManifest(manifest)
            let transactionID = UUID()
            let stem = transactionID.uuidString.lowercased()
            var journalPrepared = false
            do {
                try commitDeletion(recording: recording, transactionID: transactionID,
                                   manifestBeforeSHA256: digest(beforeData), manifestData: afterData,
                                   prepared: &journalPrepared)
                let notes = recording.transcripts.reduce(Int64(0)) { $0 + $1.byteCount }
                return ArchiveDeletionReceipt(recordingID: id, audioBytes: recording.byteCount, noteBytes: notes)
            } catch {
                if !journalPrepared { cleanupUnprepared(stem) }
                throw error
            }
        }
    }

    /// Resume only valid, bounded journals. Unjournaled leftovers are reported and retained.
    public func recover() throws -> RecoveryReport {
        try files.locked { try loadAndRecover().report }
    }

    /// Creates a new portable local directory. No upload, deletion, decoding or ASR is performed.
    /// Keep the explicitly chosen local parent's security-scoped access alive until this call returns.
    public func exportSnapshot(recordingID: UUID, revisions: SnapshotRevisionSelection,
                               toParentDirectory parent: URL, limits snapshotLimits: SnapshotLimits = SnapshotLimits()) throws -> ArchiveSnapshotReceipt {
        try exportSnapshot(recordingID: recordingID, revisions: revisions, toParentDirectory: parent,
                           limits: snapshotLimits, snapshotID: UUID(), checkpoint: nil)
    }

    // Deterministic identity and fault boundaries are internal test facilities, not a production overwrite API.
    func exportSnapshot(recordingID: UUID, revisions: SnapshotRevisionSelection, toParentDirectory parent: URL,
                        limits snapshotLimits: SnapshotLimits = SnapshotLimits(), snapshotID: UUID,
                        checkpoint: (@Sendable (SnapshotCheckpoint) throws -> Void)?) throws -> ArchiveSnapshotReceipt {
        try snapshotLimits.validate()
        return try files.locked {
            guard var recording = try loadAndRecover().manifest.recordings.first(where: { $0.id == recordingID }) else {
                throw ArchiveError.recordingNotFound
            }
            let selection: String
            switch revisions {
            case .all: selection = "all_revisions_at_locked_selection"
            case .selected(let ids):
                let unique = Set(ids)
                guard unique.count == ids.count, unique.isSubset(of: Set(recording.transcripts.map(\.id))) else {
                    throw SnapshotError.invalidSelection
                }
                recording.transcripts = recording.transcripts.filter { unique.contains($0.id) }
                selection = "explicit_revision_ids"
            }
            return try SnapshotExporter(source: files, archiveLimits: limits, limits: snapshotLimits, checkpoint: checkpoint)
                .export(recording: recording, selection: selection, parent: parent, id: snapshotID)
        }
    }

    private var maximumNoteBytes: Int64 { Int64(limits.maximumTranscriptBytes) * 8 + 8_192 }

    private func receipt(_ recording: ArchivedRecording, reused: Bool) throws -> ArchiveReceipt {
        try files.verifyLocation()
        return ArchiveReceipt(recording: recording,
                       audioURL: files.rootURL.appendingPathComponent(recording.audioRelativePath),
                       reusedExistingContent: reused, verifiedAt: Date())
    }

    private func noteReceipt(_ recording: ArchivedRecording, revision: TranscriptRevision, reused: Bool) throws -> NoteReceipt {
        try files.verifyLocation()
        return NoteReceipt(recording: recording, revision: revision,
                    noteURL: files.rootURL.appendingPathComponent("notes").appendingPathComponent(revision.filename(recordingID: recording.id)),
                    reusedExistingRevision: reused)
    }

    private func verifyAudio(_ recording: ArchivedRecording) throws {
        guard try files.verify(in: files.audio.value, name: recording.audioFilename, sha256: recording.sha256,
                               size: recording.byteCount, limit: limits.maximumFileBytes) else { throw ArchiveError.archivedContentChanged }
    }

    private func verifyNote(_ revision: TranscriptRevision, recordingID: UUID) throws {
        guard try files.verify(in: files.notes.value, name: revision.filename(recordingID: recordingID),
                               sha256: revision.noteSHA256, size: revision.byteCount, limit: maximumNoteBytes) else {
            throw ArchiveError.archivedContentChanged
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func encodeManifest(_ manifest: Manifest) throws -> Data {
        try validate(manifest)
        let data = try encoder().encode(manifest)
        guard data.count <= limits.maximumManifestBytes else { throw ArchiveError.manifestSizeLimitExceeded }
        return data
    }

    private func loadManifest() throws -> (manifest: Manifest, exists: Bool) {
        guard let data = try files.readSmall(in: files.root.value, name: "manifest.json", limit: limits.maximumManifestBytes) else {
            return (Manifest(), false)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { throw ArchiveError.invalidManifest }
        try validate(manifest)
        return (manifest, true)
    }

    private func validate(_ manifest: Manifest) throws {
        guard manifest.version == 1, manifest.recordings.count <= limits.maximumRecordings else { throw ArchiveError.invalidManifest }
        var ids = Set<UUID>()
        var contentDigests = Set<String>()
        var revisionIDs = Set<UUID>()
        func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        for item in manifest.recordings {
            guard ids.insert(item.id).inserted, contentDigests.insert(item.sha256).inserted,
                  (try? validatedTitle(item.title)) == item.title,
                  validDigest(item.sha256), (1...limits.maximumFileBytes).contains(item.byteCount),
                  supportedExtensions.contains(item.fileExtension),
                  item.importedAt.timeIntervalSince1970.isFinite, item.checksumVerifiedAt.timeIntervalSince1970.isFinite,
                  item.recordedAt?.timeIntervalSince1970.isFinite != false,
                  item.transcripts.count <= limits.maximumRevisionsPerRecording else { throw ArchiveError.invalidManifest }
            var inputDigests = Set<String>()
            for (index, revision) in item.transcripts.enumerated() {
                guard revisionIDs.insert(revision.id).inserted, revision.number == index + 1,
                      (try? validatedTitle(revision.title)) == revision.title,
                      validDigest(revision.inputSHA256), validDigest(revision.noteSHA256),
                      inputDigests.insert(revision.inputSHA256).inserted,
                      (1...maximumNoteBytes).contains(revision.byteCount), revision.createdAt.timeIntervalSince1970.isFinite else {
                    throw ArchiveError.invalidManifest
                }
            }
        }
    }

    private func apply(_ mutation: Mutation, to manifest: inout Manifest) throws {
        switch mutation {
        case .imported(let recording):
            guard recording.transcripts.isEmpty else { throw ArchiveError.invalidJournal }
            if var existing = manifest.recordings.first(where: { $0.id == recording.id }) {
                existing.transcripts = []
                guard existing == recording else { throw ArchiveError.invalidJournal }
            } else {
                manifest.recordings.append(recording)
            }
        case .transcript(let recordingID, let revision):
            guard let index = manifest.recordings.firstIndex(where: { $0.id == recordingID }) else { throw ArchiveError.invalidJournal }
            if let existing = manifest.recordings[index].transcripts.first(where: { $0.id == revision.id }) {
                guard existing == revision else { throw ArchiveError.invalidJournal }
            } else {
                guard revision.number == manifest.recordings[index].transcripts.count + 1 else { throw ArchiveError.invalidJournal }
                manifest.recordings[index].transcripts.append(revision)
            }
        case .deleted(let recording):
            // The missing case is needed only after the delete manifest was published.
            try validate(Manifest(recordings: [recording]))
            if let index = manifest.recordings.firstIndex(where: { $0.id == recording.id }) {
                guard manifest.recordings[index] == recording else { throw ArchiveError.invalidJournal }
                manifest.recordings.remove(at: index)
            }
        }
        try validate(manifest)
    }

    private func destination(_ mutation: Mutation) throws -> (directory: Int32, filename: String, sha256: String, size: Int64, limit: Int64) {
        switch mutation {
        case .imported(let recording):
            return (files.audio.value, recording.audioFilename, recording.sha256, recording.byteCount, limits.maximumFileBytes)
        case .transcript(let recordingID, let revision):
            return (files.notes.value, revision.filename(recordingID: recordingID), revision.noteSHA256, revision.byteCount, maximumNoteBytes)
        case .deleted:
            throw ArchiveError.invalidJournal
        }
    }

    private func commit(_ mutation: Mutation, transactionID: UUID, manifestData: Data, prepared: inout Bool) throws {
        let stem = transactionID.uuidString.lowercased()
        let journal = Journal(transactionID: transactionID, mutation: mutation)
        try files.writeExclusive(try encoder().encode(journal), name: stem + ".journal")
        try ArchiveFileSystem.synchronize(files.staging.value)
        prepared = true
        try checkpoint?(.journalDurable)
        try Task.checkCancellation()
        let target = try destination(mutation)
        try files.publish(stageName: stem + ".blob", to: target.directory, filename: target.filename)
        try checkpoint?(.filePublished)
        try Task.checkCancellation()
        try files.writeExclusive(manifestData, name: stem + ".manifest")
        try files.replaceManifest(stageName: stem + ".manifest")
        try checkpoint?(.manifestPublished)
        try Task.checkCancellation()
        try cleanupCommitted(stem)
    }

    private func verifyDeletionContents(_ recording: ArchivedRecording) throws {
        try verifyAudio(recording)
        for revision in recording.transcripts { try verifyNote(revision, recordingID: recording.id) }
    }

    private func removeDeletionContents(_ recording: ArchivedRecording) throws {
        try files.removeVerified(in: files.audio.value, name: recording.audioFilename,
                                 sha256: recording.sha256, size: recording.byteCount, limit: limits.maximumFileBytes)
        for revision in recording.transcripts {
            try files.removeVerified(in: files.notes.value, name: revision.filename(recordingID: recording.id),
                                     sha256: revision.noteSHA256, size: revision.byteCount, limit: maximumNoteBytes)
        }
        // Make even previously completed unlinks durable before the journal is retired.
        try ArchiveFileSystem.synchronize(files.audio.value)
        try ArchiveFileSystem.synchronize(files.notes.value)
    }

    private var maximumJournalBytes: Int { limits.maximumManifestBytes + 8_192 }

    private func commitDeletion(recording: ArchivedRecording, transactionID: UUID,
                                manifestBeforeSHA256: String, manifestData: Data, prepared: inout Bool) throws {
        let stem = transactionID.uuidString.lowercased()
        let journal = Journal(transactionID: transactionID, mutation: .deleted(recording),
                              deletionManifestBeforeSHA256: manifestBeforeSHA256,
                              deletionManifestAfterSHA256: digest(manifestData))
        let journalData = try encoder().encode(journal)
        guard journalData.count <= maximumJournalBytes else { throw ArchiveError.manifestSizeLimitExceeded }
        try files.writeExclusive(journalData, name: stem + ".journal")
        try ArchiveFileSystem.synchronize(files.staging.value)
        prepared = true
        try checkpoint?(.journalDurable)
        try Task.checkCancellation()
        try files.writeExclusive(manifestData, name: stem + ".manifest")
        try files.replaceManifest(stageName: stem + ".manifest")
        try checkpoint?(.manifestPublished)
        try Task.checkCancellation()
        try removeDeletionContents(recording)
        try checkpoint?(.fileRemoved)
        try cleanupCommitted(stem)
    }

    private func loadAndRecover() throws -> (manifest: Manifest, report: RecoveryReport) {
        let loaded = try loadManifest()
        var manifest = loaded.manifest
        var manifestExists = loaded.exists
        var recovered = 0
        let names = try files.stageNames()
        for name in names where name.hasSuffix(".journal") {
            let stem = String(name.dropLast(".journal".count))
            guard let transactionID = UUID(uuidString: stem), transactionID.uuidString.lowercased() == stem else {
                throw ArchiveError.invalidJournal
            }
            guard let data = try files.readSmall(in: files.staging.value, name: name, limit: maximumJournalBytes),
                  let journal = try? JSONDecoder().decode(Journal.self, from: data),
                  journal.version == 1, journal.transactionID == transactionID else { throw ArchiveError.invalidJournal }
            switch journal.mutation {
            case .deleted(let recording):
                guard manifestExists,
                      let before = journal.deletionManifestBeforeSHA256,
                      let after = journal.deletionManifestAfterSHA256 else { throw ArchiveError.invalidJournal }
                let current = digest(try encodeManifest(manifest))
                if current == before {
                    guard manifest.recordings.first(where: { $0.id == recording.id }) == recording else {
                        throw ArchiveError.invalidJournal
                    }
                    // Before publishing the delete manifest, all files must still exist and match.
                    try verifyDeletionContents(recording)
                    try apply(journal.mutation, to: &manifest)
                    let manifestData = try encodeManifest(manifest)
                    guard digest(manifestData) == after else { throw ArchiveError.invalidJournal }
                    try files.removeStageIfPresent(stem + ".manifest")
                    try files.writeExclusive(manifestData, name: stem + ".manifest")
                    try files.replaceManifest(stageName: stem + ".manifest")
                    manifestExists = true
                } else if current == after {
                    guard !manifest.recordings.contains(where: { $0.id == recording.id }) else {
                        throw ArchiveError.invalidJournal
                    }
                    try validate(Manifest(recordings: [recording]))
                } else {
                    throw ArchiveError.invalidJournal
                }
                // An interrupted cleanup may have removed only some exact files.
                try removeDeletionContents(recording)
            case .imported, .transcript:
                guard journal.deletionManifestBeforeSHA256 == nil,
                      journal.deletionManifestAfterSHA256 == nil else { throw ArchiveError.invalidJournal }
                try apply(journal.mutation, to: &manifest)
                let manifestData = try encodeManifest(manifest)
                let target = try destination(journal.mutation)
                if try !files.verify(in: target.directory, name: target.filename, sha256: target.sha256, size: target.size, limit: target.limit) {
                    guard try files.verify(in: files.staging.value, name: stem + ".blob", sha256: target.sha256, size: target.size, limit: target.limit) else {
                        throw ArchiveError.missingRecoveryData
                    }
                    try files.publish(stageName: stem + ".blob", to: target.directory, filename: target.filename)
                }
                // This filename is bound to the validated transaction. No wildcard cleanup is performed.
                try files.removeStageIfPresent(stem + ".manifest")
                try files.writeExclusive(manifestData, name: stem + ".manifest")
                try files.replaceManifest(stageName: stem + ".manifest")
                manifestExists = true
            }
            try cleanupCommitted(stem)
            recovered += 1
        }
        return (manifest, RecoveryReport(recoveredTransactions: recovered, retainedUnjournaledFiles: try files.stageNames().count))
    }

    private func cleanupUnprepared(_ stem: String) {
        // Best effort only for this call's newly allocated UUID; never remove source or published content.
        for suffix in [".blob", ".manifest", ".journal"] { try? files.removeStageIfPresent(stem + suffix) }
    }

    private func cleanupCommitted(_ stem: String) throws {
        // Leave the journal until the other staging entries are gone, so an interrupted cleanup can be retried.
        try files.removeStageIfPresent(stem + ".blob")
        try files.removeStageIfPresent(stem + ".manifest")
        try files.removeStageIfPresent(stem + ".journal")
        try ArchiveFileSystem.synchronize(files.staging.value)
    }
}
