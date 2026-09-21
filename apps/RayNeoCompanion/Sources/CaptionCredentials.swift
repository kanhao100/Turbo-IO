import Foundation
import Security
import RayNeoCaptions

enum CaptionCredentials {
    enum StorageError: Error, Equatable { case keychain(Int32) }
    private static func query(options: CaptionOptions) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: options.credentialService,
         kSecAttrAccount as String: options.credentialAccount]
    }
    static func read(options: CaptionOptions) -> String? {
        var request = query(options: options)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, options: CaptionOptions) throws {
        // Each provider has an isolated Keychain namespace; Azure also separates regions.
        guard CaptionStreamingAPI.validKey(key) else {
            throw CaptionFailure.invalidConfiguration
        }
        let request = query(options: options)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request; attributes.forEach { item[$0.key] = $0.value }
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw StorageError.keychain(inserted) }
        } else if status != errSecSuccess { throw StorageError.keychain(status) }
    }
    static func remove(options: CaptionOptions) throws {
        let status = SecItemDelete(query(options: options) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain(status) }
    }
}
