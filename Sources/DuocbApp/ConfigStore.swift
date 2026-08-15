import Foundation

/// The non-secret half of this installation's state, mirroring the desktop
/// config file (crates/duocb/src/config.rs): the device name, this device's
/// signed self-card, and the trusted peers' cards.
///
/// A file rather than UserDefaults because the peer list is a structured list
/// that grows to 128 entries, and a file rather than the Keychain because none
/// of it is secret — a card is the thing you hand out. The two actual secrets,
/// the application private key and the permanent suffix, are in the Keychain
/// (see `Keychain.swift`).
///
/// The desktop's `identity_secret` and `device_suffix` fields are deliberately
/// absent here for that reason; everything else lines up field for field, under
/// the same snake_case names, so the two are readable side by side.
struct DuocbConfig: Codable, Equatable {
    var version: Int
    var myName: String?
    var selfCard: String?
    var peers: [String]
    var channel: SignalChannel

    static let currentVersion = 1

    static let empty = DuocbConfig(
        version: currentVersion,
        myName: nil,
        selfCard: nil,
        peers: [],
        channel: .lanThenNostr
    )

    enum CodingKeys: String, CodingKey {
        case version
        case myName = "my_name"
        case selfCard = "self_card"
        case peers
        case channel
    }

    init(
        version: Int,
        myName: String?,
        selfCard: String?,
        peers: [String],
        channel: SignalChannel
    ) {
        self.version = version
        self.myName = myName
        self.selfCard = selfCard
        self.peers = peers
        self.channel = channel
    }

    /// Tolerant of missing keys so a file written by an older build still
    /// loads with defaults rather than resetting the whole identity.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        myName = try container.decodeIfPresent(String.self, forKey: .myName)
        selfCard = try container.decodeIfPresent(String.self, forKey: .selfCard)
        peers = try container.decodeIfPresent([String].self, forKey: .peers) ?? []
        channel = try container.decodeIfPresent(SignalChannel.self, forKey: .channel)
            ?? .lanThenNostr
    }
}

/// Loads and saves `DuocbConfig` as JSON in Application Support.
///
/// Writes go through a temp file and an atomic rename, matching the desktop's
/// save path: a config half-written by a crash or a kill would cost the user
/// their whole trusted-device list, which is only recoverable by re-trading
/// cards with every device.
enum ConfigStore {
    static func load() -> DuocbConfig {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(DuocbConfig.self, from: data)
        else { return .empty }
        return config
    }

    @discardableResult
    static func save(_ config: DuocbConfig) -> Bool {
        guard let url = fileURL() else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // .atomic is the temp-and-rename the desktop does by hand.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("duocb", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}
