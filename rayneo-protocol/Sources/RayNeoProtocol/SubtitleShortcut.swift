import Foundation

/// Changes only the double-tap action in a freshly queried crown configuration.
public enum SubtitleShortcut {
    public static let liveCaptions = 4
    public enum Failure: Error { case missingConfiguration, invalidAction }
    public static func replacingDouble(in crown: [String: Any], with action: Int = liveCaptions) throws -> [String: Any] {
        guard SubtitleTranslateWire.integer(crown["double"]) != nil,
              SubtitleTranslateWire.integer(crown["longPress"]) != nil else { throw Failure.missingConfiguration }
        guard (0...9).contains(action) else { throw Failure.invalidAction }
        var changed = crown; changed["double"] = action; return changed
    }
}
