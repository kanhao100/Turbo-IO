import Foundation

/// Flat AppCueingSettings fields captured with successful native Strix
/// 1.0.4.12 prepare/start receipts. They are also emitted by the official
/// settings serializer (0x16729c0); type 7 must retain the entire layout.
struct TeleprompterNativeLayout: Codable, Equatable {
    var size: Int = 18
    var width: Int = 492
    var leading: Int = 4
    var countdown: Int = 3
    var gear: Int = 3
    var depth: Int = 1

    static let `default` = TeleprompterNativeLayout()
    var valid: Bool {
        [18, 20, 24].contains(size) && (240...492).contains(width) &&
            (0...16).contains(leading) && (0...10).contains(countdown) &&
            (1...3).contains(gear) && (1...3).contains(depth)
    }
    func settings(scrollMode: Int, speed: Int) -> [String: Any] {
        ["scroll": scrollMode, "speed": speed, "countdown": countdown,
         "gear": gear, "depth": depth, "size": size, "width": width, "leading": leading]
    }
}

/// An immutable copy of exactly the bytes sent to the glasses. Type 2 prepare
/// and type 3 start carry the same mode, position, size and FNV-1a checksum.
/// Native field evidence is in the official AppCueingStartRequest serializer
/// (0x25d45b8 → 0x25d4628), plus the existing Harmony/official-addon path.
/// The official headless page calculation maps byte offset → character/line
/// → byte table entry (0x166feb0/0x166fca4/0x166fa80/0x166fbc8). Its protocol-Y
/// cache is not the returned page offset. Firmware normalization and non-ASCII
/// highlight behavior still require hardware calibration.
struct TeleprompterNativeDocument {
    let data: Data
    let speed: Int
    let scrollMode: Int
    let initialOffset: Int
    let boundaries: Set<Int>
    let checksum: String
    let layout: TeleprompterNativeLayout

    /// The file transport exposes the basename to firmware. It must be the
    /// document ID itself, as in the verified official-addon transfer path.
    static func fileURL(directory: URL, did: String) throws -> URL {
        guard !did.isEmpty, did.utf8.count <= 128,
              did.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw DeviceFeatureError.invalidPacket
        }
        return directory.appendingPathComponent(did, isDirectory: false)
    }

    init(text: String, speed: Int, scrollMode: Int, initialOffset: Int,
         layout: TeleprompterNativeLayout = .default) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 12_000, text.utf8.count <= 48_000,
              (60...240).contains(speed), (1...3).contains(scrollMode), layout.valid else {
            throw DeviceFeatureError.invalidPacket
        }
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text { offset += String(character).utf8.count; boundaries.insert(offset) }
        guard boundaries.contains(initialOffset) else { throw DeviceFeatureError.invalidPacket }
        let data = Data(text.utf8)
        var hash: UInt32 = 2_166_136_261
        for byte in data { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        self.data = data
        self.speed = speed
        self.scrollMode = scrollMode
        self.initialOffset = initialOffset
        self.boundaries = boundaries
        self.layout = layout
        checksum = String(format: "%08x", hash)
    }

    func command(type: UInt32, did: String, speedOverride: Int? = nil) throws -> [String: Any] {
        let speed = speedOverride ?? self.speed
        guard [2, 3].contains(type), DeviceBusinessWire.identifier(["did": did], "did") != nil,
              (60...240).contains(speed) else {
            throw DeviceFeatureError.invalidPacket
        }
        var body: [String: Any] = ["action": 1, "did": did, "total": data.count,
            "checksum": checksum,
            "pageOffset": initialOffset, "highLightOffset": initialOffset]
        body.merge(layout.settings(scrollMode: scrollMode, speed: speed)) { _, new in new }
        if type == 3 { body["code"] = 1 }
        return body
    }

    func settingsCommand(did: String, speed: Int) throws -> [String: Any] {
        guard DeviceBusinessWire.identifier(["did": did], "did") != nil,
              (60...240).contains(speed) else { throw DeviceFeatureError.invalidPacket }
        var body = layout.settings(scrollMode: scrollMode, speed: speed)
        body["action"] = 1; body["did"] = did
        return body
    }

    /// Reply to an owned glasses start request without starting a different
    /// manuscript or rebuilding/transferring the file. The native response
    /// serializer (0x25d48d4) permits the same flat settings and position.
    func startResponse(did: String, offset: Int, speed: Int) throws -> [String: Any] {
        guard boundaries.contains(offset) else { throw DeviceFeatureError.invalidPacket }
        var body = try settingsCommand(did: did, speed: speed)
        body["action"] = 2; body["code"] = 1
        body["pageOffset"] = offset; body["highLightOffset"] = offset
        return body
    }
}

/// Native position acknowledgements do not echo a request ID. Keep one type 8
/// in flight, coalesce subsequent ticks, and discard queued motion after a
/// wheel gesture so a late response cannot send an older automatic position.
struct TeleprompterNativeProgressQueue {
    struct Position: Equatable { var page: Int; var highlight: Int }
    private(set) var awaitingAcknowledgement = false
    private(set) var queued: Position?
    private(set) var confirmedPosition: Position?
    private var inFlight: Position?
    private var mayConfirmInFlight = false
    mutating func enqueue(_ position: Position) -> Position? {
        if awaitingAcknowledgement { queued = position; return nil }
        awaitingAcknowledgement = true
        inFlight = position; mayConfirmInFlight = true
        return position
    }
    mutating func acknowledge() -> Position? {
        guard awaitingAcknowledgement else { return nil }
        confirmedPosition = mayConfirmInFlight ? inFlight : nil
        inFlight = nil; mayConfirmInFlight = false
        awaitingAcknowledgement = false
        let position = queued; queued = nil
        return position.flatMap { enqueue($0) }
    }
    mutating func manualAssist() {
        queued = nil; confirmedPosition = nil
        // Keep the acknowledgement barrier, but a late automatic receipt
        // cannot replace a newer position chosen on the glasses.
        mayConfirmInFlight = false
    }
}

/// A rewind is a temporary reading aid in native linear-scroll mode. This
/// policy never treats forward playback receipts as fresh wheel activity.
/// Explicit app holds and unpaired native pauses stay paused.
struct TeleprompterUniformAssistPolicy {
    enum Phase: Equatable { case idle, awaitingPause, holding, awaitingResume }
    enum Action: Equatable { case none, pause, resume }
    private(set) var phase: Phase = .idle
    private(set) var resumeAt: TimeInterval?
    private(set) var nativePauseAt: TimeInterval?
    var holding: Bool { phase == .awaitingPause || phase == .holding || (phase == .awaitingResume && resumeAt != nil) }

    mutating func rewind(now: TimeInterval, holdSeconds: Double, canPause: Bool,
                         pauseAssociationSeconds: Double = 0) -> Action {
        guard now.isFinite, holdSeconds.isFinite, (0...5).contains(holdSeconds),
              pauseAssociationSeconds.isFinite, (0...2).contains(pauseAssociationSeconds) else { return .none }
        if phase == .awaitingResume || holding { resumeAt = now + holdSeconds; return .none }
        guard phase == .idle else { return .none }
        // Firmware has no verified "wheel pause" flag. Only the nearby pair
        // native pause → backwards position can be associated with one dial
        // gesture. A bare pause has no deadline and never resumes by itself.
        if !canPause, let nativePauseAt, pauseAssociationSeconds > 0,
           now >= nativePauseAt, now - nativePauseAt <= pauseAssociationSeconds {
            phase = .holding; resumeAt = now + holdSeconds; self.nativePauseAt = nil
            return .none
        }
        guard canPause else { return .none }
        nativePauseAt = nil
        phase = .awaitingPause; resumeAt = now + holdSeconds
        return .pause
    }
    mutating func nativePause(now: TimeInterval, wasRunning: Bool) {
        cancel()
        if wasRunning, now.isFinite { nativePauseAt = now }
    }
    mutating func pauseAcknowledged(now: TimeInterval) -> Action {
        guard phase == .awaitingPause else { return .none }
        phase = .holding
        return tick(now: now)
    }
    mutating func tick(now: TimeInterval, readyToResume: Bool = true) -> Action {
        guard phase == .holding, let resumeAt, now >= resumeAt, readyToResume else { return .none }
        phase = .awaitingResume; self.resumeAt = nil
        return .resume
    }
    mutating func resumeAcknowledged(canPause: Bool) -> Action {
        guard phase == .awaitingResume else { return .none }
        if resumeAt != nil, canPause { phase = .awaitingPause; return .pause }
        cancel(); return .none
    }
    mutating func cancel() { phase = .idle; resumeAt = nil; nativePauseAt = nil }
}
