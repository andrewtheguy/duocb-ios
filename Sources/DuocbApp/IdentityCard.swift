import Foundation

/// Output-buffer sizes for the FFI's write-into-my-buffer helpers, named after
/// the `DUOCB_*_BUF_LEN` constants in duocb.h. Every one of those calls reports
/// `0` for "too small" rather than truncating silently, so these are generous
/// on purpose: an undersized buffer is a bug, not a degraded result.
enum DuocbBuffer {
    static let identity = 128
    static let suffix = 16
    static let name = 64
    static let publicKey = 128
    static let fingerprint = 64
    static let pairingCode = 128
    static let pin = 16
    static let card = 4096
    static let cardInfo = 1024
    static let joinIP = 256
    /// `duocb_pin_progress`'s JSON object.
    static let pinProgress = 128
    /// `duocb_resolve_join_ip`'s single dotted-quad answer.
    static let joinIPAddress = 32
    static let error = 1024
}

/// A verified identity card's public detail, decoded from
/// `duocb_identity_card_info` (and from the `info` of a `peer_card_received`
/// event, which carries the same shape).
///
/// Everything here is public by design — a card is the token you hand another
/// device so it will trust you, and it holds no private key. The one field that
/// carries weight is `fingerprint`: it is taken over the public key rather than
/// the card, so it survives a re-mint. It is this card's half of the card-setup
/// pairing code, and the value a trusted-device row shows for out-of-band
/// re-checks.
struct IdentityCardInfo: Equatable {
    /// The full display identity, e.g. "mac-book_a7B2c3D4".
    let name: String
    let shortName: String
    let suffix: String
    /// 64-char hex — the stable key for trust, selection and deduplication.
    let publicKey: String
    let npub: String
    /// Human-comparable digest of `publicKey`, e.g. "A1B2 C3D4 …".
    let fingerprint: String
    let createdAt: UInt64
    let expiresAt: UInt64
    let remainingSecs: UInt64
    /// Trust has lapsed: both sides refuse to pair on this card, and the only
    /// way back is a fresh one from its owner.
    let expired: Bool
    /// Advisory, and only meaningful for this device's *own* card: less than a
    /// week of life left, so re-mint it before handing it out again.
    let needsRenewal: Bool

    /// Decode a signed card. nil when it does not parse, is not correctly
    /// signed, or breaks the schema — the same verifying path a pasted card
    /// takes on the desktop.
    static func parse(card: String) -> IdentityCardInfo? {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.cardInfo)
        let rc = card.withCString { duocb_identity_card_info($0, &buf, buf.count) }
        guard rc == 1 else { return nil }
        return decode(json: String(cString: buf))
    }

    /// Decode the JSON object shape both `duocb_identity_card_info` and the
    /// `peer_card_received` event's `info` field use.
    static func decode(json: String) -> IdentityCardInfo? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return decode(object: object)
    }

    static func decode(object: [String: Any]) -> IdentityCardInfo? {
        guard let name = object["name"] as? String,
              let publicKey = object["public_key"] as? String
        else { return nil }
        return IdentityCardInfo(
            name: name,
            shortName: object["short_name"] as? String ?? name,
            suffix: object["suffix"] as? String ?? "",
            publicKey: publicKey,
            npub: object["npub"] as? String ?? "",
            fingerprint: object["fingerprint"] as? String ?? "",
            createdAt: (object["created_at"] as? NSNumber)?.uint64Value ?? 0,
            expiresAt: (object["expires_at"] as? NSNumber)?.uint64Value ?? 0,
            remainingSecs: (object["remaining_secs"] as? NSNumber)?.uint64Value ?? 0,
            expired: object["expired"] as? Bool ?? false,
            needsRenewal: object["needs_renewal"] as? Bool ?? false
        )
    }

    var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }

    /// The expiry line shown under a trusted-device row, matching the desktop's
    /// wording — "expires 2026-09-13", or "expired" once it has lapsed.
    var expiryText: String {
        if expired { return "expired" }
        return "expires \(expiryDateText)"
    }

    /// The expiry date alone, for a message that supplies its own wording.
    var expiryDateText: String { Self.dayFormatter.string(from: expiryDate) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// One row of the trusted-device list: a peer's stored signed card plus its
/// decoded detail. Identified by public key, which is what trust is keyed on
/// and what a join names.
struct TrustedPeer: Identifiable, Equatable {
    /// The signed card as stored, handed back to the FFI verbatim.
    let card: String
    let info: IdentityCardInfo

    var id: String { info.publicKey }

    init?(card: String) {
        guard let info = IdentityCardInfo.parse(card: card) else { return nil }
        self.card = card
        self.info = info
    }
}

/// Where the rendezvous records are put and looked for. Governs card setup and
/// clipboard sessions alike, so it reads as "how the two devices find each
/// other", not "how card setup works".
///
/// The desktop fixes this at launch (`--lan-only` / `--nostr-only`). iOS has no
/// command line, so it is a setting, applied when a session starts — which is
/// the same guarantee in practice, since a running session never changes
/// channel underneath itself. **Both devices must be reachable on a channel
/// they share.**
enum SignalChannel: String, CaseIterable, Codable {
    /// The default: local network first, nostr relays as fallback. Sub-second
    /// for two devices in one room, and still reaches a device elsewhere.
    case lanThenNostr = "lan_then_nostr"
    /// No third-party server at all — a pair of devices with no internet still
    /// works. Needs the Local Network permission.
    case lanOnly = "lan_only"
    /// Relays only: no mDNS query, no side-channel listener.
    case nostrOnly = "nostr_only"

    var title: String {
        switch self {
        case .lanThenNostr: "Local network, then internet"
        case .lanOnly: "Local network only"
        case .nostrOnly: "Internet only"
        }
    }

    var note: String {
        switch self {
        case .lanThenNostr:
            """
            Finds your other device on the same network first and falls back to \
            relay servers, so it works in the same room and across the internet.
            """
        case .lanOnly:
            """
            No third-party server is involved and no internet is needed, but both \
            devices must be on the same network. Asks for Local Network permission.
            """
        case .nostrOnly:
            """
            Relay servers only — no local network lookup at all. Useful when \
            multicast is blocked, and the only option when the devices are on \
            different networks and you want to skip the local search.
            """
        }
    }

    /// Whether the local network takes part, which is what makes the manual
    /// host-IP entry meaningful during card setup.
    var usesLAN: Bool { self != .nostrOnly }

    /// A one-line hub badge naming a non-default channel; nil on the default,
    /// where the card-setup screen's note is the only place it is spelled out
    /// (desktop parity).
    var badge: String? {
        self == .lanThenNostr ? nil : title
    }
}
