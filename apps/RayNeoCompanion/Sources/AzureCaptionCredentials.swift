import Foundation
import Security
import RayNeoCaptions

enum AzureCaptionCredentials {
    private static let service = "io.turboio.companion.azure-speech.v1"
    private static func query(region: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: region]
    }
    static func read(region: String) -> String? {
        var request = query(region: region)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, region: String) throws {
        // Azure keys aren't DashScope sk- keys. No secret in defaults, logs or source.
        guard (16...512).contains(key.utf8.count), !key.contains(where: { $0.isWhitespace }) else {
            throw CaptionFailure.invalidConfiguration
        }
        let request = query(region: region)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request; attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CaptionFailure.closed }
        } else if status != errSecSuccess { throw CaptionFailure.closed }
    }
    static func remove(region: String) throws {
        let status = SecItemDelete(query(region: region) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CaptionFailure.closed }
    }
}
