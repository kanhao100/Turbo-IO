import Foundation
import RayNeoCaptions

protocol SubtitleSessionWriting: AnyObject {
    func event(_ entry: CaptionEntry)
    func pcm(_ data: Data)
    func gap()
    func finish(_ record: SubtitleSessionRecord, completion: @escaping (Bool) -> Void)
}

/// One queue preserves PCM/event/close order. Backpressure is an explicit failure,
/// never a silent claim that a dropped recording is complete.
final class CaptionDiskSink: SubtitleSessionWriting {
    let directory: URL
    private let journal: CaptionJournal
    private let recording: CaptionWAVWriter?
    private let queue = DispatchQueue(label: "companion.captions.disk", qos: .utility)
    private let slots = DispatchSemaphore(value: 64)
    private var failed = false
    private let onFailure: () -> Void
    init(root: URL, id: UUID, recordAudio: Bool, record: SubtitleSessionRecord? = nil, onFailure: @escaping () -> Void) throws {
        self.onFailure = onFailure
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var rootURL = root, values = URLResourceValues(); values.isExcludedFromBackup = true
        try rootURL.setResourceValues(values)
        let sessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard sessions.count < 100 else { throw CaptionFailure.limit }
        // Reserve room for this session (256 MiB audio + journal/export). Never prune history.
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let scan = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        var size = 0
        while let url = scan?.nextObject() as? URL {
            let info = try url.resourceValues(forKeys: Set(keys))
            if info.isRegularFile == true { size += info.fileSize ?? 0 }
            guard size < 736 * 1_024 * 1_024 else { throw CaptionFailure.limit }
        }
        journal = try CaptionJournal(root: root, id: id); directory = journal.directory
        recording = recordAudio ? try CaptionWAVWriter(directory: directory) : nil
        if let record { try record.write(to: directory) }
    }
    func event(_ entry: CaptionEntry) { enqueue { try self.journal.append(entry) } }
    func pcm(_ data: Data) {
        guard recording != nil else { return }
        enqueue { try self.recording?.append(data) }
    }
    func gap() { enqueue { try self.recording?.finishSegment() } }
    private func enqueue(_ action: @escaping () throws -> Void) {
        guard slots.wait(timeout: .now()) == .success else { onFailure(); return }
        queue.async { [self] in
            defer { slots.signal() }
            guard !failed else { return }
            do { try action() } catch { failed = true; DispatchQueue.main.async(execute: onFailure) }
        }
    }
    func close(completion: @escaping () -> Void) {
        queue.async { [self] in
            do { try recording?.close(); try journal.close() }
            catch { DispatchQueue.main.async(execute: onFailure) }
            DispatchQueue.main.async(execute: completion)
        }
    }
    func finish(_ record: SubtitleSessionRecord, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            var final = record
            do { try recording?.close(); try journal.close() }
            catch { failed = true }
            if failed { final.state = .interrupted; final.endReason = "存储未完整完成；已收到的文件保留" }
            do { try final.write(to: directory) } catch { failed = true }
            let success = !failed
            DispatchQueue.main.async { completion(success) }
        }
    }
}
