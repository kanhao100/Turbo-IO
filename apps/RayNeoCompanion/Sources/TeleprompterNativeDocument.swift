import Foundation

/// An immutable copy of exactly the bytes sent to the glasses. Type 2 prepare
/// and type 3 start carry the same mode, position, size and FNV-1a checksum.
/// Native field evidence is in the official AppCueingStartRequest serializer
/// (0x25d45b8 → 0x25d4628), plus the existing Harmony/official-addon path.
struct TeleprompterNativeDocument {
    let data: Data
    let speed: Int
    let scrollMode: Int
    let initialOffset: Int
    let boundaries: Set<Int>
    let checksum: String

    init(text: String, speed: Int, scrollMode: Int, initialOffset: Int) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 12_000, text.utf8.count <= 48_000,
              (60...240).contains(speed), (1...3).contains(scrollMode) else {
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
        checksum = String(format: "%08x", hash)
    }

    func command(type: UInt32, did: String) throws -> [String: Any] {
        guard [2, 3].contains(type), DeviceBusinessWire.identifier(["did": did], "did") != nil else {
            throw DeviceFeatureError.invalidPacket
        }
        var body: [String: Any] = ["action": 1, "did": did, "total": data.count,
            "checksum": checksum, "scroll": scrollMode, "speed": speed,
            "pageOffset": initialOffset, "highLightOffset": initialOffset]
        if type == 3 { body["code"] = 1 }
        return body
    }
}
