import Foundation

/// One row of the device list: a peer's presence record decoded from a
/// `peer_list` event. Identified by the permanent suffix, which is stable
/// across renames and refreshes.
struct PeerInfo: Identifiable, Equatable {
    /// The full display identity, e.g. "mac-book_a7B2c3D4".
    let display: String
    let name: String
    let suffix: String
    /// The peer's presence record carries a node id — it can be joined.
    let hosting: Bool
    /// Seen within the presence online window (a few minutes).
    let online: Bool
    let lastSeenUnix: UInt64

    var id: String { suffix }

    /// Humanized record age, like the desktop hub: "just now", "3m ago", ….
    var lastSeenText: String {
        let now = UInt64(max(0, Date.now.timeIntervalSince1970))
        let secs = now > lastSeenUnix ? now - lastSeenUnix : 0
        switch secs {
        case ..<60: return "just now"
        case ..<3600: return "\(secs / 60)m ago"
        case ..<86_400: return "\(secs / 3600)h ago"
        default: return "\(secs / 86_400)d ago"
        }
    }

    /// Decode the `peers` array of a `peer_list` event.
    static func parse(_ value: Any?) -> [PeerInfo] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.compactMap { peer in
            guard let display = peer["display"] as? String,
                  let name = peer["name"] as? String,
                  let suffix = peer["suffix"] as? String
            else { return nil }
            return PeerInfo(
                display: display,
                name: name,
                suffix: suffix,
                hosting: peer["hosting"] as? Bool ?? false,
                online: peer["online"] as? Bool ?? false,
                lastSeenUnix: (peer["last_seen_unix"] as? NSNumber)?.uint64Value ?? 0
            )
        }
    }
}
