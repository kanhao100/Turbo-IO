import Foundation

/// Received PCM16/16k/mono only. Not an independent microphone or offline backfill.
/// Serial disk queue only. 60-second pieces, bounded total bytes, no full audio in RAM.
public final class CaptionWAVWriter {
    private let directory: URL
    private let segmentBytes: Int
    private let byteLimit: Int
    private var file: FileHandle?
    private var bytes = 0, total = 0, synchronizedAt = 0, index = 0
    private var closed = false
    public private(set) var files: [URL] = []
    public init(directory: URL, segmentSeconds: Int = 60, byteLimit: Int = 256 * 1_024 * 1_024) throws {
        guard (1...300).contains(segmentSeconds), byteLimit > 0 else { throw CaptionFailure.invalidConfiguration }
        self.directory = directory; segmentBytes = segmentSeconds * 32_000; self.byteLimit = byteLimit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? finishSegment() }
    public func append(_ pcm: Data) throws {
        guard !closed else { throw CaptionFailure.closed }
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 65_536,
              total <= byteLimit - pcm.count else { throw CaptionFailure.limit }
        var offset = 0
        while offset < pcm.count {
            if file == nil { try openSegment() }
            let count = min(segmentBytes - bytes, pcm.count - offset)
            try file?.write(contentsOf: pcm.subdata(in: offset..<(offset + count)))
            bytes += count; total += count; offset += count
            if bytes == segmentBytes { try finishSegment() }
            else if bytes - synchronizedAt >= 32_000 { try checkpoint() }
        }
    }
    /// Close at an input gap so a single piece never implies uninterrupted audio.
    public func finishSegment() throws {
        guard let handle = file else { return }
        try checkpoint(); try handle.close(); file = nil
    }
    public func close() throws { try finishSegment(); closed = true }
    private func openSegment() throws {
        guard index < 512 else { throw CaptionFailure.limit }
        let url = directory.appendingPathComponent(String(format: "audio-%04d.wav", index))
        #if os(iOS)
        try Self.header(bytes: 0).write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Self.header(bytes: 0).write(to: url, options: .withoutOverwriting)
        #endif
        file = try FileHandle(forWritingTo: url); try file?.seekToEnd()
        index += 1; bytes = 0; synchronizedAt = 0; files.append(url)
    }
    private func checkpoint() throws {
        guard let file else { return }
        try file.seek(toOffset: 0); try file.write(contentsOf: Self.header(bytes: bytes))
        try file.seekToEnd(); try file.synchronize(); synchronizedAt = bytes
    }
    private static func header(bytes: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u16(_ n: UInt16) { data.append(UInt8(n & 255)); data.append(UInt8(n >> 8)) }
        func u32(_ n: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((n >> shift) & 255)) } }
        u32(UInt32(bytes + 36)); data.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(bytes)); return data
    }
}
