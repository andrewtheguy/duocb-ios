import Foundation
import Security

/// Stores this device's permanent 8-character identity suffix in the Keychain.
///
/// The suffix is not a secret, but the Keychain is the right durability for
/// it: `…ThisDeviceOnly` means it is never synced to iCloud or restored onto
/// another device — and the suffix *is* this device's identity, so it must
/// never travel. It is minted once, on the first call, via
/// `duocb_generate_suffix` and never regenerated; clearing the shared secret
/// keeps it (matching the desktop's `device_suffix` config field).
enum SuffixStore {
    private static let service = "com.andrewtheguy.duocb.deviceSuffix"
    private static let account = "default"

    /// The permanent suffix, minted and persisted on the first call.
    static func loadOrCreate() -> String {
        if let existing = load(), !existing.isEmpty {
            return existing
        }
        var buf = [CChar](repeating: 0, count: 64)
        guard duocb_generate_suffix(&buf, buf.count) == 1 else {
            return "" // unreachable: the buffer is ample and never NULL
        }
        let suffix = String(cString: buf)
        save(suffix)
        return suffix
    }

    private static func save(_ suffix: String) {
        guard let data = suffix.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    private static func load() -> String? {
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
              let suffix = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return suffix
    }
}
