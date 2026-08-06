import Foundation
import Security

/// Minimal macOS Keychain access for the Supabase API key.
/// The key is NEVER stored in source, env defaults, or logs — only the Keychain.
enum Keychain {
    /// Attributes-only presence probe — never materializes the secret into a
    /// String just to test existence (security review: the full-read probe
    /// heap-allocates an unzeroed service key on every view appearance).
    static func exists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Read a generic-password item. Returns nil if absent or empty (fail-closed).
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Upsert a generic-password item (for a future in-app settings flow).
    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // replace if present
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Pin to this device, unlocked-only: keeps the key off iCloud Keychain sync
        // and unencrypted backups. A high-privilege key must never leave the Mac.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
