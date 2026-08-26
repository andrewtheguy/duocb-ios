import Foundation

/// The non-secret half of this installation's state: the device name, this
/// device's signed self-card, trusted peers' cards, and the saved channel.
/// Shared fields mirror the desktop config (`crates/duocb/src/config.rs`).
///
/// A file rather than UserDefaults because the peer list is a structured list
/// that grows to 128 entries, and a file rather than the Keychain because none
/// of it is secret — a card is the thing you hand out. The application private
/// key, permanent suffix, and iroh transport key are in the Keychain (see
/// `Keychain.swift`).
///
/// The desktop's `identity_secret` and `device_suffix` fields are deliberately
/// absent here for that reason. Shared fields use the same snake_case names;
/// `channel` is iOS-only persisted state because the desktop chooses it at
/// launch.
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

    /// Tolerant of *missing optional* keys in otherwise valid JSON — a file
    /// edited by hand still yields the fields it does carry rather than
    /// throwing away a trusted-device list over an absent `channel`.
    ///
    /// Tolerance stops at the shape: `version` is checked against
    /// `currentVersion` by `ConfigStore.load()`, which refuses anything else
    /// outright, exactly as the desktop's loader does. There is no migration
    /// path and there is not meant to be one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required, unlike everything below it: a file with no version is not a
        // file this build wrote, and guessing one for it would defeat the check.
        version = try container.decode(Int.self, forKey: .version)
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
    /// What `load` found. The distinction that matters is the last case: a file
    /// that exists but cannot be read is *not* the same as no file at all, and
    /// treating it as one would hand back an empty config that the next save
    /// writes straight over the top of — turning a transient read failure, or a
    /// config from a build that is not this one, into a permanently lost
    /// trusted-device list.
    enum Outcome {
        /// A file was read and decoded.
        case loaded(DuocbConfig)
        /// No file yet — a first launch, or an identity that was reset.
        case missing
        /// A file is there and unusable. Carries the reason for the banner.
        case unreadable(String)
    }

    static func load() -> Outcome {
        guard let url = fileURL() else {
            return .unreadable("This device has no Application Support directory")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError
            // A read of a missing file reports `fileReadNoSuchFile` (260), not
            // the bare `fileNoSuchFile` (4); both are matched so the distinction
            // cannot quietly turn a first launch into an unreadable config.
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {
            return .missing
        } catch {
            return .unreadable("Settings could not be read: \(error.localizedDescription)")
        }
        guard let config = try? JSONDecoder().decode(DuocbConfig.self, from: data) else {
            return .unreadable("Settings are corrupt or from a different version of the app")
        }
        guard config.version == DuocbConfig.currentVersion else {
            return .unreadable("""
                Settings are version \(config.version); this app uses version \
                \(DuocbConfig.currentVersion) and does not convert older ones
                """)
        }
        return .loaded(config)
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
