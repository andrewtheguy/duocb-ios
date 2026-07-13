import Foundation
import Security

/// Stores the shared auth token in the iOS Keychain — encrypted, OS-managed
/// storage for the one real secret in the app. Everything else (device name,
/// role) is non-sensitive and lives in UserDefaults; the name is written only
/// at the same commit points as the token (see SessionController).
///
/// Accessibility is `…AfterFirstUnlockThisDeviceOnly`: readable after the first
/// unlock following a boot (so it survives backgrounding), never synced to
/// iCloud, and never restored onto another device.
enum TokenStore {
    private static let service = "com.andrewtheguy.duocb.authToken"
    private static let account = "default"

    /// Persist `token`, replacing any existing value, and report whether it is
    /// now stored in the Keychain. Empty strings are treated as a clear (and
    /// report `false`) so we never store a blank secret. The caller relies on
    /// the return value to avoid advancing setup with a secret that never
    /// actually reached secure storage.
    @discardableResult
    static func save(_ token: String) -> Bool {
        guard !token.isEmpty, let data = token.data(using: .utf8) else {
            clear()
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Update in place when the item exists; otherwise (including the first
        // save, which returns errSecItemNotFound) replace it outright. Report
        // the add's status so a silent Keychain failure can't leave the setup
        // believing a secret was saved when none reached the Keychain.
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    /// Read back the stored token, or nil if none is set.
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
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return token
    }

    /// Remove the stored token.
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
