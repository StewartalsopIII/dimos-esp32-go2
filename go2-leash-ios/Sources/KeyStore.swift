// Robot AES-128 key in the iOS keychain. The install step may drop a one-use
// file at Documents/robot.key; it is imported once and deleted. The value is
// never displayed, logged or written anywhere else.

import Foundation
import Security

enum KeyStore {
    private static let service = "org.aiwhisperers.Go2Leash"
    private static let account = "go2-aes-128"

    /// Imports Documents/robot.key if present. Returns a status line safe to show.
    static func importDroppedKeyFile() -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let file = docs.appendingPathComponent("robot.key")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              (try? Go2Protocol.keyBytes(hex: text)) != nil
        else { return "dropped key file was invalid; deleted" }
        return save(text.trimmingCharacters(in: .whitespacesAndNewlines))
            ? "robot key imported into keychain; file deleted"
            : "keychain save failed; file deleted"
    }

    static func save(_ hex: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(hex.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
