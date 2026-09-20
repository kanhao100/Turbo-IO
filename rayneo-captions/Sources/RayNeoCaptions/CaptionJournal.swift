import Foundation

public struct CaptionEntry: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case started, final, unfinished, gap, stopped }
    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String, date: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.date = date; self.kind = kind; self.text = text
    }
}

/// A fresh journal per explicitly started session. Caller owns a serial disk queue.
/// Only final sentences and an explicitly labelled unfinished tail are persisted.
public final class CaptionJournal {
    public let directory: URL
    private let handle: FileHandle
    private var size = 0
    private var closed = false
    public init(root: URL, id: UUID) throws {
        directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("captions.jsonl")
        #if os(iOS)
        try Data().write(to: file, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data().write(to: file, options: .withoutOverwriting)
        #endif
        handle = try FileHandle(forWritingTo: file)
    }
    deinit { try? handle.close() }
    public func append(_ entry: CaptionEntry) throws {
        guard !closed else { throw CaptionFailure.closed }
        guard entry.text.utf8.count <= 32_768 else { throw CaptionFailure.limit }
        var data = try JSONEncoder().encode(entry); data.append(10)
        guard size + data.count <= 16 * 1_024 * 1_024 else { throw CaptionFailure.limit }
        try handle.write(contentsOf: data); try handle.synchronize(); size += data.count
    }
    public func close() throws {
        guard !closed else { return }
        closed = true; try handle.synchronize(); try handle.close()
    }
    public static func load(_ directory: URL) throws -> [CaptionEntry] {
        let url = directory.appendingPathComponent("captions.jsonl")
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              (info.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw CaptionFailure.limit }
        let data = try Data(contentsOf: url)
        var result: [CaptionEntry] = []
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            // A killed process may leave a torn final line; never append to it.
            if index == lines.count - 1 && data.last != 10 { break }
            // JSON escaping may expand a 32 KiB sentence by up to six times.
            guard line.count <= 262_144 else { throw CaptionFailure.limit }
            result.append(try JSONDecoder().decode(CaptionEntry.self, from: Data(line)))
        }
        return result
    }
    public static func exportText(_ entries: [CaptionEntry]) -> String {
        let format = ISO8601DateFormatter()
        return "Turbo IO Azure 字幕\n时间为手机收到事件的时间，不是音频采样对齐时间。\n\n" + entries.map {
            "[\(format.string(from: $0.date))] [\($0.kind.rawValue)] \($0.text)"
        }.joined(separator: "\n\n")
    }
}
