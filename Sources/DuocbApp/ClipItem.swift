import Foundation

/// A clipboard item that passed through the session — a received item in the
/// inbox, or the last item sent in the outbox. Lives only in memory, never
/// written to disk. Mirrors the desktop app's ClipItem (crates/duocb/src/app/item.rs):
/// same CRC-32/ISO-HDLC fingerprint and `XXXX-XXXX` display so the two devices'
/// readouts can be compared by eye.
struct ClipItem: Identifiable {
    let id = UUID()
    let text: String
    /// When it was received (inbox) or sent (outbox).
    let timestamp: Date
    /// CRC-32 of the payload, computed once on creation.
    let crc32: UInt32
    /// When the peek view was opened, or nil if collapsed. Auto-hides
    /// `peekTimeout` after this (see SessionController.tickPeeks).
    var peekedAt: Date?

    /// Max characters shown in the peek view (matches desktop PEEK_LIMIT).
    static let peekLimit = 4096
    /// How long a peeked item stays open before auto-hiding (desktop PEEK_TIMEOUT).
    static let peekTimeout: TimeInterval = 15

    init(text: String, timestamp: Date = .now) {
        self.text = text
        self.timestamp = timestamp
        self.crc32 = Self.crc32(of: text)
    }

    var expanded: Bool { peekedAt != nil }

    /// CRC-32 fingerprint formatted as two four-hex groups for readability,
    /// identical to the desktop's `crc32_display`.
    var crcDisplay: String {
        String(format: "%04X-%04X", crc32 >> 16, crc32 & 0xFFFF)
    }

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .binary)
    }

    /// The peek text, truncated to `peekLimit` characters like the desktop.
    var peekText: String {
        text.count > Self.peekLimit ? String(text.prefix(Self.peekLimit)) + "…" : text
    }

    /// CRC-32/ISO-HDLC over the payload bytes — a short fingerprint the user
    /// can compare across the two devices. Same algorithm as the desktop.
    private static func crc32(of text: String) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in text.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

/// One live connection path (direct or relay), decoded from a `conn_path` event.
struct ConnPath: Identifiable {
    let id = UUID()
    let kind: String     // "direct" | "relay" | "other"
    let display: String  // human line like "Direct 1.2.3.4:52186 (rtt 1ms)"
    let selected: Bool   // whether iroh currently routes traffic over this path

    static func parse(_ value: Any?) -> [ConnPath] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.map {
            ConnPath(
                kind: $0["kind"] as? String ?? "other",
                display: $0["display"] as? String ?? "",
                selected: $0["selected"] as? Bool ?? false)
        }
    }
}
