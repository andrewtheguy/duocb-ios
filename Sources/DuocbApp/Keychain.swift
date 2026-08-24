import Foundation
import Security
import UIKit

/// The three things this app keeps in the Keychain: the application private
/// key (`IdentityStore`), this device's permanent name suffix (`SuffixStore`)
/// and its iroh transport key (`IrohKeyStore`).
///
/// Everything else — the device name, this device's signed self-card, and the
/// trusted peers' cards — lives in an ordinary JSON file (`ConfigStore`).
/// Cards are public by design: a card is the thing you hand out, and it carries
/// no private key, so the Keychain would buy nothing for them.
///
/// Accessibility is `…AfterFirstUnlockThisDeviceOnly` for every item: readable
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
/// Deliberately unrelated to iroh's transport key (`IrohKeyStore`), which is
/// never a credential.
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

    /// The permanent suffix, minted and persisted on the first call. nil when it
    /// could not be minted or could not be stored.
    ///
    /// A suffix that only exists in memory is worse than none: the next launch
    /// would mint a different one, so this device's identity would rename itself
    /// behind the user's back and every card it has handed out would name a
    /// device nobody can find. So the write has to succeed before the value
    /// counts as this device's — the caller refuses to finish setup otherwise,
    /// the same way `IdentityStore.save` gates the private key.
    static func loadOrCreate() -> String? {
        if let existing = Keychain.load(service: service) {
            return existing
        }
        var buf = [CChar](repeating: 0, count: DuocbBuffer.suffix)
        guard duocb_generate_suffix(&buf, buf.count) == 1 else {
            return nil // the buffer is ample and never NULL, so this is a bug
        }
        let suffix = String(cString: buf)
        guard Keychain.save(suffix, service: service) else { return nil }
        return suffix
    }
}

/// This device's iroh transport key, the secret behind its node id.
///
/// The desktop mints this fresh on every launch because a config directory can
/// be copied between machines, and two live endpoints presenting one node id
/// would shadow each other on the relays. An iOS app's storage cannot be
/// cloned that way — the Keychain item is this-device-only and never restored
/// from a backup onto another device — so here it is minted once and reused,
/// and the node id survives relaunches. As a second guard it is stored
/// together with `identifierForVendor`: a key found under a different vendor
/// id (a reinstall after every app from this vendor was removed) is discarded
/// and a fresh one minted.
///
/// Read once per process (`shared`), so every session this process starts
/// passes the same key; the FFI refuses a different one anyway.
enum IrohKeyStore {
    private static let service = "com.andrewtheguy.duocb.irohSecret"
    /// Stored form: `<vendor id>:<64 hex chars>`.
    private static let separator: Character = ":"

    /// The key every `duocb_start` in this process passes as `iroh_secret`.
    /// Resolved on first use and never re-read.
    static let shared: String? = loadOrCreate()

    private static func loadOrCreate() -> String? {
        let vendor = UIDevice.current.identifierForVendor?.uuidString
        if let stored = Keychain.load(service: service),
           let split = stored.firstIndex(of: separator)
        {
            let storedVendor = String(stored[..<split])
            let secret = String(stored[stored.index(after: split)...])
            if let vendor, storedVendor == vendor, !secret.isEmpty {
                return secret
            }
        }
        var buf = [CChar](repeating: 0, count: DuocbBuffer.irohSecret)
        guard duocb_generate_iroh_secret(&buf, buf.count) == 1 else {
            return nil // the buffer is ample and never NULL, so this is a bug
        }
        let secret = String(cString: buf)
        // No vendor id (it can be nil right after a reboot, before the device
        // is unlocked): use the fresh key for this run but do not persist it —
        // the next launch will have the id and mint the one that sticks.
        guard let vendor else { return secret }
        guard Keychain.save("\(vendor)\(separator)\(secret)", service: service) else {
            return secret
        }
        return secret
    }
}
