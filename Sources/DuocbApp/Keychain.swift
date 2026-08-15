import Foundation
import Security

/// The two things this app keeps in the Keychain: the application private key
/// (`IdentityStore`) and this device's permanent name suffix (`SuffixStore`).
///
/// Everything else — the device name, this device's signed self-card, and the
/// trusted peers' cards — lives in an ordinary JSON file (`ConfigStore`).
/// Cards are public by design: a card is the thing you hand out, and it carries
/// no private key, so the Keychain would buy nothing for them.
///
/// Accessibility is `…AfterFirstUnlockThisDeviceOnly` for both items: readable
/// after the first unlock following a boot (so a session survives
/// backgrounding), never synced to iCloud, and never restored onto another
/// device. That last part is the point — an application identity *is* this
/// installation, and two devices presenting the same key would be a trust bug,
/// not a convenience.
enum Keychain {
    /// Persist `value` under `service`, replacing anything already there.
    /// An empty value is treated as a clear and reports failure, so a blank
    /// secret is never stored. Returns whether the value is now in the Keychain.
    @discardableResult
    static func save(_ value: String, service: String) -> Bool {
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            clear(service: service)
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
        // Update first, and on any failure delete and add outright rather than
        // inspecting the status: an item can be present but unreadable (wrong
        // accessibility from an earlier install), and a plain replace is the
        // one path that recovers from every such state.
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        if status != errSecSuccess {
            // Worth naming: the whole setup flow refuses to advance on a failed
            // write, so a silent false here looks like a UI that ignores taps.
            // -34018 (errSecMissingEntitlement) is the one that bites in
            // practice — an unsigned build has no application-identifier, so
            // the keychain refuses it. Sign the build (ad-hoc is enough on the
            // Simulator) rather than working around it.
            NSLog("[duocb] keychain write to %@ failed: OSStatus %d", service, status)
        }
        return status == errSecSuccess
    }

    static func load(service: String) -> String? {
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
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    static func clear(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// One item per service; the account is a fixed placeholder.
    private static let account = "default"
}

/// This installation's application private key (NIP-19 `nsec`), the credential
/// that signs its identity card and authenticates the wire protocol.
///
/// Deliberately unrelated to iroh's transport key, which is ephemeral and never
/// persisted anywhere.
enum IdentityStore {
    private static let service = "com.andrewtheguy.duocb.identitySecret"

    static func load() -> String? { Keychain.load(service: service) }

    @discardableResult
    static func save(_ nsec: String) -> Bool { Keychain.save(nsec, service: service) }

    static func clear() { Keychain.clear(service: service) }
}

/// This device's permanent 8-character identity suffix.
///
/// Minted once via `duocb_generate_suffix` and never regenerated: it is what
/// keeps `<name>_<suffix>` stable across a rename, so it must outlive both the
/// name and the identity. Resetting the identity keeps it (matching the
/// desktop's `device_suffix` config field, which a new keypair does not touch).
enum SuffixStore {
    private static let service = "com.andrewtheguy.duocb.deviceSuffix"

    /// The permanent suffix, minted and persisted on the first call.
    static func loadOrCreate() -> String {
        if let existing = Keychain.load(service: service) {
            return existing
        }
        var buf = [CChar](repeating: 0, count: DuocbBuffer.suffix)
        guard duocb_generate_suffix(&buf, buf.count) == 1 else {
            return "" // unreachable: the buffer is ample and never NULL
        }
        let suffix = String(cString: buf)
        Keychain.save(suffix, service: service)
        return suffix
    }
}
