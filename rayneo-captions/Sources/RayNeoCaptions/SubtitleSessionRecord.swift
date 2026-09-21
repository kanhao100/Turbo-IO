import Foundation

public struct SubtitleSessionRecord: Codable, Identifiable, Equatable {
    public enum State: String, Codable { case active, completed, interrupted }
    public let version: Int
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var endedAt: Date?
    public let service: CaptionService
    public let language: String
    public let savesAudio: Bool
    public var state: State = .active
    public var receivedPCMBytes = 0
    public var finalSentences = 0
    public var gaps = 0
    public var endReason = ""
    public var preview: String?
    public var audioSeconds: TimeInterval { Double(receivedPCMBytes) / 32_000 }
    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), options: CaptionOptions) {
        version = 1; self.id = id; self.title = title; self.createdAt = createdAt
        service = options.service; language = options.language; savesAudio = options.recordAudio
    }
    public func write(to directory: URL) throws {
        guard directory.lastPathComponent == id.uuidString, title.count <= 120,
              endReason.utf8.count <= 2048 else { throw CaptionFailure.corruptArchive }
        let data = try JSONEncoder().encode(self)
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent("session.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        #endif
    }
    public static func read(from directory: URL) throws -> Self {
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw CaptionFailure.corruptArchive }
        let file = directory.appendingPathComponent("session.json")
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              (attributes.fileSize ?? Int.max) <= 65_536 else { throw CaptionFailure.corruptArchive }
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard record.version == 1, record.id.uuidString == directory.lastPathComponent,
              record.receivedPCMBytes >= 0, record.finalSentences >= 0, record.gaps >= 0,
              record.title.count <= 120 else { throw CaptionFailure.corruptArchive }
        return record
    }
}
