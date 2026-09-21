import Foundation

/// Accumulates final segments until the provider's utterance endpoint. A partial
/// never becomes model input, and empty recognition never interrupts an answer.
struct SpeechTurnAssembler {
    enum Event: Equatable { case began(UUID), transcript(UUID, String), ended(UUID, String), retracted(UUID) }
    enum Failure: Error { case limit }
    private var turn: UUID?
    private var committed = "", partial = ""
    private var count = 0
    mutating func result(_ text: String, final: Bool) throws -> [Event] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count + committed.utf8.count + 1 <= 8_192 else { throw Failure.limit }
        var events: [Event] = []
        if turn == nil, !value.isEmpty {
            guard count < 64 else { throw Failure.limit }
            count += 1; turn = UUID(); events.append(.began(turn!))
        }
        if final { committed = Self.join(committed, value); partial = "" }
        else { partial = value }
        if let turn, !value.isEmpty { events.append(.transcript(turn, Self.join(committed, partial))) }
        return events
    }
    mutating func endpoint() -> Event? {
        defer { turn = nil; committed = ""; partial = "" }
        guard let turn else { return nil }
        return committed.isEmpty ? .retracted(turn) : .ended(turn, committed)
    }
    private static func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty else { return second }; guard !second.isEmpty else { return first }
        // Keep words from adjacent Latin segments apart without inserting gaps into Chinese.
        let separator = first.last?.isASCII == true && second.first?.isASCII == true ? " " : ""
        return first + separator + second
    }
}
