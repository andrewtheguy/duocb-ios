import Foundation
import Observation

/// Central view model: owns the Rust FFI handle, polls its event queue on a
/// timer, and mirrors the desktop app's state machine.
///
/// # One handle, four roles, and a hub that runs nothing
///
/// The hub is **pure local state**. The trusted-device list is read from this
/// app's own storage; nothing is broadcast and nothing is discovered, so no
/// runtime instance exists while the hub is on screen. A handle is created only
/// for a session, and there is at most one at a time:
///
/// - `start` / `join` — a clipboard session between two devices that already
///   trust each other's cards;
/// - `cardHost` / `cardJoin` — **card setup**, a short-lived session that
///   exists only to swap identity cards and never carries clipboard content.
///
/// # Trust is imported, never inferred
///
/// A card that arrives over card setup is verified as well-formed and correctly
/// signed and nothing more — the PIN is short enough that possession of it must
/// not be enough to become a trusted device. So `incomingCard` is parked for
/// the user to check the pairing code matches the other device's screen, and
/// only `importIncomingCard()` writes it to the trusted list.
///
/// # Persistence commit points
///
/// The private key is saved to the Keychain the moment it is generated or
/// imported; the device name and the freshly minted self-card the moment the
/// name is confirmed; a peer's card the moment its pairing code is confirmed.
/// Editing a field alone never persists. The permanent suffix is minted once on
/// first launch and survives an identity reset.
@Observable @MainActor
final class SessionController {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case resolving
        case connecting
        case authenticating
        case connected
        case reconnecting(attempt: Int, max: Int)
        case failed(String)
    }

    enum Role: String {
        case start, join
        case cardHost = "card_host"
        case cardJoin = "card_join"

        /// Card setup never carries clipboard traffic; it trades cards and ends.
        var isCardSetup: Bool { self == .cardHost || self == .cardJoin }
        /// Hosts show a PIN or listen; joiners dial.
        var isHost: Bool { self == .start || self == .cardHost }
    }

    /// A card handed over by card setup, waiting on the user's pairing-code
    /// check. Holding the encoded card alongside the decoded detail means
    /// importing stores exactly the bytes that were verified.
    struct IncomingCard: Equatable {
        let card: String
        let info: IdentityCardInfo
    }

    // MARK: - Session state

    private(set) var phase: Phase = .idle
    private(set) var nodeID: String?
    private(set) var peerNodeID: String?
    /// Join role: the display identity of the device being joined.
    private(set) var joinedPeer: String?
    /// Non-nil while the connection-path sheet is up; refreshed by queryConnPath.
    var connPaths: [ConnPath]?
    /// Card host: the current PIN ("XXXX-XXXX"), until a peer pairs.
    private(set) var pinDisplay: String?
    /// Card host: when the displayed PIN rotates away.
    private(set) var pinDeadline: Date?
    /// Card host: this device's LAN IPv4, shown so the joiner can type it for
    /// the manual-IP side channel (nil when the LAN channel is off, or before
    /// an address is known).
    private(set) var hostLanIP: String?
    /// The peer's card, verified but not yet trusted — the confirmation screen.
    private(set) var incomingCard: IncomingCard?
    /// Received items, newest first, capped like the desktop inbox.
    private(set) var inbox: [ClipItem] = []
    /// The last successfully sent item.
    private(set) var outbox: ClipItem?
    /// Last error message, shown as a banner; errors are not always fatal.
    var lastError: String?

    // MARK: - Standing identity

    /// This installation's application private key (`nsec`), or nil before
    /// setup. Backed by the Keychain.
    private(set) var identitySecret: String? = IdentityStore.load()
    /// This device's permanent identity suffix, minted on first launch. nil
    /// only when the Keychain refused the write, which blocks setup — see
    /// `SuffixStore.loadOrCreate`.
    let suffix: String? = SuffixStore.loadOrCreate()
    /// The device name, self-card, trusted peer cards and channel choice.
    private(set) var config: DuocbConfig = .empty
    /// Non-nil when a config file exists that could not be read. Everything in
    /// memory is then a default rather than this device's real state, so
    /// `persist()` refuses to write over the file until the user resolves it.
    private(set) var configError: String?
    /// `config.peers`, parsed — the trusted-device rows.
    private(set) var peers: [TrustedPeer] = []

    var deviceName: String? { config.myName }
    var selfCard: String? { config.selfCard }
    var channel: SignalChannel { config.channel }

    /// Everything a session needs: a key, a confirmed name, and a self-card.
    var hasIdentity: Bool {
        identitySecret != nil && config.myName != nil && config.selfCard != nil
    }

    /// The identity other devices see, e.g. "phone_a7B2c3D4".
    var displayIdentity: String? {
        guard let name = config.myName, let suffix else { return nil }
        return "\(name)_\(suffix)"
    }

    /// This device's key fingerprint — shown on the hub, and this device's
    /// half of any card-setup pairing code.
    var ownFingerprint: String? {
        identitySecret.flatMap(Self.identityFingerprint)
    }

    /// The single pairing code the card-setup confirmation screen shows,
    /// derived from this device's self-card and the incoming one. Both devices
    /// render the identical value and the user compares one code across the
    /// two screens; nil while no card is pending.
    var incomingPairingCode: String? {
        guard let own = config.selfCard, let incoming = incomingCard else { return nil }
        return Self.pairingCode(own, incoming.card)
    }

    /// The self-card's decoded detail, for the hub's expiry line.
    var selfCardInfo: IdentityCardInfo? {
        config.selfCard.flatMap(IdentityCardInfo.parse(card:))
    }

    // MARK: - Constants

    /// Max retained inbox items (matches desktop MAX_INBOX_ITEMS).
    private static let maxInboxItems = 5
    /// The FFI contract guarantees that every JSON event fits in 2 MiB.
    private static let maxEventBufferSize = 2 * 1024 * 1024
    /// The trusted-peer cap the FFI enforces (duocb_core MAX_TRUSTED_PEERS).
    static let maxTrustedPeers = 128

    private var handle: OpaquePointer?
    private var currentRole: Role?
    /// True while an old runtime instance is still shutting down off-thread;
    /// the FFI allows one instance per process, so new starts wait for the
    /// teardown completion instead of racing it.
    private var stopping = false
    private var pollTimer: Timer?
    private var eventBuffer = [CChar](repeating: 0, count: 64 * 1024)
    /// The one in-flight send (desktop parity: one outbox slot), promoted to
    /// `outbox` when the runtime confirms with `item_sent`.
    private var pendingOutbox: String?
    /// The last session start, for Reconnect after a failure.
    private(set) var lastSession: (role: Role, peerKey: String?, pin: String?, ip: String?)?

    var isSessionActive: Bool { handle != nil }

    /// The role of a session that has been asked for but has no handle yet.
    ///
    /// Starting a session while another is still winding down is asynchronous:
    /// `teardown` clears the handle immediately and `startRuntime` runs only
    /// once `duocb_stop` has returned off-thread. Without this the app would
    /// drop back to the hub for that gap and then jump to the session screen —
    /// a flash that reads like the tap did not register. `.starting` with no
    /// handle is exactly that window; every other phase falls through to the
    /// handle-based answer, so a start that fails still lands on the failure.
    private var pendingRole: Role? {
        guard handle == nil, phase == .starting else { return nil }
        return lastSession?.role
    }

    /// The running session's role, or the one that is about to start.
    /// `currentRole` and `handle` are set and cleared together, so this is nil
    /// exactly when no session owns the screen.
    private var activeRole: Role? { currentRole ?? pendingRole }

    /// Card setup is on screen: the PIN/dialing screen, not the clipboard one.
    var isCardSetupActive: Bool { activeRole?.isCardSetup == true }
    /// A clipboard session is on screen.
    var isClipboardSessionActive: Bool { activeRole.map { !$0.isCardSetup } ?? false }
    var isHostingRole: Bool { activeRole?.isHost ?? false }

    init() {
        duocb_init_logging()
        switch ConfigStore.load() {
        case .loaded(let stored):
            config = stored
        case .missing:
            break // first launch: the defaults are correct
        case .unreadable(let reason):
            // Left at the defaults deliberately, and flagged: the real file
            // stays on disk untouched until the user says to discard it.
            configError = reason
        }
        reloadPeers()
        renewSelfCardIfNeeded()
    }

    /// Give up on a config file that could not be read and start from defaults,
    /// overwriting it. The only way out of `configError`, and deliberately an
    /// explicit user action — the alternative is silently discarding a trusted
    /// list that a later build, or a fixed permission, could still have read.
    func discardUnreadableConfig() {
        configError = nil
        config = .empty
        peers = []
        persist()
    }

    #if DEBUG
    /// Text queued by `autostartFromEnvironment`, sent once connected.
    private var autosendText: String?
    /// Whether to trust a card-setup card without the pairing-code screen.
    private var autoTrustIncoming = false

    /// E2E-test hook, **Debug builds only** — the Release archive that ships
    /// does not contain it. Sets up the identity and starts a session straight
    /// from launch environment variables, so a harness can drive a pairing
    /// without UI automation. Pass via `xcrun simctl launch` with
    /// `SIMCTL_CHILD_DUOCB_AUTOSTART_*`:
    ///
    /// | variable | meaning |
    /// | --- | --- |
    /// | `NSEC` | this device's private key; omitted mints a fresh one |
    /// | `NAME` | short device name, default "phone" |
    /// | `ROLE` | `start` \| `join` \| `card_host` \| `card_join`; omit to stop at the hub |
    /// | `PEER` | `join` only: the trusted peer's hex public key |
    /// | `PIN` | `card_join` only |
    /// | `IP` | `card_join` only: the host's LAN IP for the side channel |
    /// | `CHANNEL` | `lan_then_nostr` \| `lan_only` \| `nostr_only` |
    /// | `TRUST_INCOMING` | `1` to import a traded card without the pairing-code screen |
    /// | `PEER_CARD` | a card to trust up front, so `start`/`join` can run unattended |
    /// | `SEND` | text to send once connected |
    ///
    /// `TRUST_INCOMING` deliberately bypasses the human check that card setup
    /// exists for. That is only acceptable because it cannot exist in a
    /// shipping build — never lift this out of `#if DEBUG`.
    func autostartFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        // ROLE alone is enough to arm the hook; without it this is an ordinary
        // launch. A run that supplies no key gets a fresh one, so a test starts
        // from a clean device rather than inheriting the last run's trust.
        // Logged unconditionally: a harness that sees nothing here knows the
        // variables never arrived (a missing SIMCTL_CHILD_ prefix, say) rather
        // than having to guess between that and a pairing that failed silently.
        let role = env["DUOCB_AUTOSTART_ROLE"]
        NSLog("[duocb] autostart: role=%@ active=%@",
              role ?? "(none)", isSessionActive ? "yes" : "no")
        guard !isSessionActive, role != nil else { return }

        autosendText = env["DUOCB_AUTOSTART_SEND"]
        autoTrustIncoming = env["DUOCB_AUTOSTART_TRUST_INCOMING"] == "1"
        if let channel = env["DUOCB_AUTOSTART_CHANNEL"].flatMap(SignalChannel.init(rawValue:)) {
            setChannel(channel)
        }

        // Idempotent across relaunches, which any multi-step test needs:
        // `setIdentity` deliberately clears the self-card and the whole trusted
        // list, so re-applying the key this device already has would throw away
        // the pairing the previous step just established. Only adopt a key that
        // is genuinely new.
        let provided = env["DUOCB_AUTOSTART_NSEC"]
        if let provided, provided != identitySecret {
            guard setIdentity(provided) else {
                NSLog("[duocb] autostart: could not persist the identity — Keychain write failed")
                return
            }
        } else if identitySecret == nil {
            guard setIdentity(Self.generateIdentity()) else {
                NSLog("[duocb] autostart: could not persist the identity — Keychain write failed")
                return
            }
        }
        let name = env["DUOCB_AUTOSTART_NAME"] ?? "phone"
        if config.myName != name || config.selfCard == nil {
            guard saveName(name) else {
                NSLog("[duocb] autostart: could not name this device — no suffix or no card")
                return
            }
        }
        if let card = env["DUOCB_AUTOSTART_PEER_CARD"] {
            _ = importPeerCard(card)
        }
        NSLog("[duocb] autostart: %@ ready, %d trusted, starting role=%@",
              displayIdentity ?? "?", peers.count, role ?? "")

        switch env["DUOCB_AUTOSTART_ROLE"] {
        case "start":
            startHosting()
        case "join":
            if let key = env["DUOCB_AUTOSTART_PEER"],
               let peer = peers.first(where: { $0.id == key }) {
                join(peer: peer)
            }
        case "card_host":
            startCardHost()
        case "card_join":
            if let pin = env["DUOCB_AUTOSTART_PIN"].flatMap(Self.normalizePIN) {
                joinCardSetup(pin: pin, ip: env["DUOCB_AUTOSTART_IP"])
            }
        default:
            break
        }
    }
    #endif

    // MARK: - Pure FFI helpers
    //
    // None of these touch the network or storage, so views may call them
    // freely for live validation.

    nonisolated static func generateIdentity() -> String {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.identity)
        guard duocb_generate_identity(&buf, buf.count) == 1 else { return "" }
        return String(cString: buf)
    }

    /// nil if valid, else the reason.
    nonisolated static func validateIdentity(_ nsec: String) -> String? {
        var err = [CChar](repeating: 0, count: DuocbBuffer.error)
        let rc = nsec.withCString { duocb_validate_identity($0, &err, err.count) }
        switch rc {
        case 1: return nil
        case 0: return String(cString: err)
        default: return "invalid private key"
        }
    }

    nonisolated static func identityPublicKey(_ nsec: String) -> String? {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.publicKey)
        let rc = nsec.withCString { duocb_identity_public_key($0, &buf, buf.count) }
        return rc == 1 ? String(cString: buf) : nil
    }

    nonisolated static func identityFingerprint(_ nsec: String) -> String? {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.fingerprint)
        let rc = nsec.withCString { duocb_identity_fingerprint($0, &buf, buf.count) }
        return rc == 1 ? String(cString: buf) : nil
    }

    /// The pairing code over two signed cards, order-normalized so both devices
    /// render the identical value. nil when either card fails verification or
    /// both carry the same key — a comparison that could only ever "match".
    nonisolated static func pairingCode(_ cardA: String, _ cardB: String) -> String? {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.pairingCode)
        let rc = cardA.withCString { a in
            cardB.withCString { b in
                duocb_pairing_code(a, b, &buf, buf.count)
            }
        }
        return rc == 1 ? String(cString: buf) : nil
    }

    /// nil if valid, else the reason (the Rust core's identity::validate_name).
    nonisolated static func validateName(_ name: String) -> String? {
        var err = [CChar](repeating: 0, count: DuocbBuffer.error)
        let rc = name.withCString { duocb_validate_name($0, &err, err.count) }
        switch rc {
        case 1: return nil
        case 0: return String(cString: err)
        default: return "enter a name"
        }
    }

    /// "<name>_<suffix>", for the name field's live preview.
    nonisolated static func displayIdentity(name: String, suffix: String) -> String {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.name + DuocbBuffer.suffix)
        let rc = name.withCString { namePtr in
            suffix.withCString { suffixPtr in
                duocb_display_identity(namePtr, suffixPtr, &buf, buf.count)
            }
        }
        return rc == 1 ? String(cString: buf) : "\(name)_\(suffix)"
    }

    nonisolated static func createIdentityCard(
        nsec: String,
        name: String,
        suffix: String
    ) -> String? {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.card)
        let rc = nsec.withCString { keyPtr in
            name.withCString { namePtr in
                suffix.withCString { suffixPtr in
                    duocb_create_identity_card(keyPtr, namePtr, suffixPtr, &buf, buf.count)
                }
            }
        }
        return rc == 1 ? String(cString: buf) : nil
    }

    /// nil if the card is well formed and correctly signed, else the reason.
    /// Deliberately says nothing about expiry — that is a separate question the
    /// import preview asks of `IdentityCardInfo.expired`.
    nonisolated static func validateIdentityCard(_ card: String) -> String? {
        var err = [CChar](repeating: 0, count: DuocbBuffer.error)
        let rc = card.withCString { duocb_validate_identity_card($0, &err, err.count) }
        switch rc {
        case 1: return nil
        case 0: return String(cString: err)
        default: return "invalid identity card"
        }
    }

    /// Canonical form (8 uppercase Crockford chars) of a typed card-setup PIN,
    /// or nil while it isn't valid yet. Dashes/spaces/lowercase and the I/L→1,
    /// O→0 aliases are handled by the Rust core, which also checks the trailing
    /// check digit.
    nonisolated static func normalizePIN(_ input: String) -> String? {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.pin)
        let rc = input.withCString { duocb_normalize_pin($0, &buf, buf.count) }
        return rc == 1 ? String(cString: buf) : nil
    }

    /// Drop characters a PIN cannot contain, uppercasing and mapping the I/L→1
    /// and O→0 aliases — every keystroke goes through this, so the field can
    /// never hold a character the code does not use.
    nonisolated static func sanitizePIN(_ input: String) -> String {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.pin)
        let rc = input.withCString { duocb_sanitize_pin_chars($0, &buf, buf.count) }
        return rc == 1 ? String(cString: buf) : ""
    }

    /// How many PIN characters are entered and how many a full PIN needs, for
    /// the "keep typing" hint.
    nonisolated static func pinProgress(_ input: String) -> (entered: Int, total: Int) {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.pinProgress)
        guard input.withCString({ duocb_pin_progress($0, &buf, buf.count) }) == 1,
              let data = String(cString: buf).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (0, 8) }
        return (obj["entered"] as? Int ?? 0, obj["total"] as? Int ?? 8)
    }

    /// How the host-IP entry is constrained to this device's own subnet (see
    /// `duocb_join_ip_context`). `prefix` is the locked network part the user
    /// types after (empty when no subnet was detected → free entry),
    /// `placeholder` describes the editable tail, `hint` a range hint for a
    /// partial-octet subnet, `label` the CIDR for the out-of-range message.
    struct JoinIPContext {
        var prefix: String
        var placeholder: String
        var hint: String
        var label: String
        static let empty = JoinIPContext(prefix: "", placeholder: "", hint: "", label: "")
    }

    nonisolated static func joinIPContext() -> JoinIPContext {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.joinIP)
        guard duocb_join_ip_context(&buf, buf.count) == 1,
              let data = String(cString: buf).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }
        return JoinIPContext(
            prefix: obj["prefix"] as? String ?? "",
            placeholder: obj["placeholder"] as? String ?? "",
            hint: obj["hint"] as? String ?? "",
            label: obj["label"] as? String ?? ""
        )
    }

    /// The outcome of validating the host-IP entry against this device's subnet.
    /// `.inRange` carries the full dotted-quad to pass to `joinCardSetup(ip:)`;
    /// `.empty` means browse DNS-SD instead (pass no IP).
    enum JoinIPOutcome: Equatable {
        case empty
        case inRange(String)
        case outOfRange
        case malformed
    }

    nonisolated static func resolveJoinIP(_ entry: String) -> JoinIPOutcome {
        var buf = [CChar](repeating: 0, count: DuocbBuffer.joinIPAddress)
        let rc = entry.withCString { duocb_resolve_join_ip($0, &buf, buf.count) }
        switch rc {
        case 1: return .inRange(String(cString: buf))
        case 0: return .outOfRange
        case 2: return .empty
        default: return .malformed
        }
    }

    // MARK: - Identity mutation (wizard commit points)

    /// Adopt a newly generated or imported private key, persisting it to the
    /// Keychain first and only adopting it in memory if that write succeeds —
    /// so setup never advances on a secret that did not reach secure storage.
    ///
    /// A key change invalidates everything keyed to the old one: the self-card
    /// was signed by it, and the trusted peers hold *its* public key, not the
    /// new one. Both are cleared, exactly as the desktop's reset does.
    @discardableResult
    func setIdentity(_ nsec: String) -> Bool {
        guard IdentityStore.save(nsec) else { return false }
        identitySecret = nsec
        config.selfCard = nil
        config.peers = []
        reloadPeers()
        // Keep the name as a prefill, but re-mint the card under the new key if
        // one was already confirmed.
        if let name = config.myName, let suffix {
            config.selfCard = Self.createIdentityCard(nsec: nsec, name: name, suffix: suffix)
        }
        persist()
        return true
    }

    /// Persist the confirmed device name and mint the self-card that names it.
    /// The card is the thing other devices store, so a rename means a new card
    /// — and peers keep trusting the old one until its owner hands over the new
    /// one, which is why the name is not a live-updating field.
    ///
    /// Returns whether the name was committed. The name and the card go in
    /// together or not at all: a name with no card is an identity that cannot
    /// host, join or be trusted, and the naming screen would have moved on to a
    /// hub whose every action fails.
    @discardableResult
    func saveName(_ name: String) -> Bool {
        guard let nsec = identitySecret, let suffix else { return false }
        guard let card = Self.createIdentityCard(nsec: nsec, name: name, suffix: suffix) else {
            lastError = "Could not issue this device's identity card"
            return false
        }
        config.myName = name
        config.selfCard = card
        persist()
        return true
    }

    /// Start over with a fresh application identity: a new keypair, no name, no
    /// self-card, and an empty trusted list — every peer's stored copy of the
    /// old key is now meaningless. The permanent suffix survives (desktop
    /// parity: `reset_identity` never touches `device_suffix`).
    func resetIdentity() {
        teardown {}
        IdentityStore.clear()
        identitySecret = nil
        // The channel is a transport preference, not part of the identity —
        // the desktop keeps it too (it is a launch flag there, which a reset
        // cannot touch), so losing it here would be a gratuitous difference.
        let channel = config.channel
        config = .empty
        config.channel = channel
        peers = []
        lastSession = nil
        incomingCard = nil
        // A reset is also the way out of an unreadable config: it is the one
        // action whose whole purpose is to discard what was stored.
        configError = nil
        persist()
    }

    func setChannel(_ channel: SignalChannel) {
        guard config.channel != channel else { return }
        config.channel = channel
        persist()
    }

    // MARK: - Trusted peers

    /// Import a card pasted from another device. Returns nil on success, else
    /// the reason — the same failures the desktop's paste-import reports.
    @discardableResult
    func importPeerCard(_ pasted: String) -> String? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "paste the card copied from the other device" }
        if let error = Self.validateIdentityCard(trimmed) { return error }
        guard let peer = TrustedPeer(card: trimmed) else { return "invalid identity card" }
        if let nsec = identitySecret,
           let ownKey = Self.identityPublicKey(nsec),
           peer.info.npub == ownKey {
            return "that is this device's own card"
        }
        return store(peer)
    }

    /// Trust the card card setup handed over, after the user checked the
    /// pairing code matches the other screen. This is the only path that turns
    /// a verified card into a trusted one.
    func importIncomingCard() {
        guard let incoming = incomingCard, let peer = TrustedPeer(card: incoming.card) else {
            dismissIncomingCard()
            return
        }
        // A nil pairing code means there was nothing the user could have
        // compared — the peer sent back this device's own card, or no
        // self-card exists. Refused here rather than only by the disabled
        // button, so the DEBUG auto-trust hook can never store a card the
        // human path would refuse. (An expired card is refused by store().)
        guard incomingPairingCode != nil else {
            lastError = "no pairing code could be built for that card, so it was not imported"
            dismissIncomingCard()
            return
        }
        if let error = store(peer) {
            lastError = error
        }
        dismissIncomingCard()
    }

    /// Decline the card and end card setup without trusting anything.
    func dismissIncomingCard() {
        incomingCard = nil
        phase = .idle
        teardown {}
    }

    func removePeer(publicKey: String) {
        guard let peer = peers.first(where: { $0.id == publicKey }) else { return }
        config.peers.removeAll { $0 == peer.card }
        reloadPeers()
        persist()
    }

    /// Add or replace a peer, keyed on public key: a re-traded card from the
    /// same device is a *renewal*, so it replaces the stored copy rather than
    /// appearing twice. Returns nil on success, else the reason.
    ///
    /// The single place trust is granted, so a card that arrived over card
    /// setup is held to exactly the same rules as one pasted in by hand
    /// (desktop parity: `store_peer_card` in app/mod.rs).
    private func store(_ peer: TrustedPeer) -> String? {
        // Storing a lapsed card would record trust that can never pair, so it
        // is refused here rather than at the first Join. Cards already in the
        // list are a different question — those stay, in warning colour, so
        // they remain visible and removable.
        if peer.info.expired {
            return """
                That identity card expired on \(peer.info.expiryDateText) — \
                get a fresh one from the other device
                """
        }
        if let existing = peers.first(where: { $0.id == peer.id }) {
            config.peers.removeAll { $0 == existing.card }
        } else if peers.count >= Self.maxTrustedPeers {
            return "this device already trusts the maximum of \(Self.maxTrustedPeers) devices"
        }
        config.peers.append(peer.card)
        reloadPeers()
        persist()
        return nil
    }

    private func reloadPeers() {
        peers = config.peers.compactMap(TrustedPeer.init(card:))
            .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    /// Write the config, unless an unreadable file is still on disk. Refusing
    /// there is the point of tracking `configError` at all: what is in memory is
    /// a set of defaults, and saving it would replace a trusted-device list that
    /// was never actually read with an empty one.
    private func persist() {
        if let configError {
            lastError = "\(configError). Nothing was saved."
            return
        }
        if !ConfigStore.save(config) {
            lastError = "Could not save this device's settings"
        }
    }

    /// Re-mint the self-card once it is inside its renewal window, so the card
    /// the user copies always has most of its life ahead of it. Called at
    /// launch; a card with under a week left is replaced in place.
    private func renewSelfCardIfNeeded() {
        guard let nsec = identitySecret, let name = config.myName, let suffix else { return }
        // No card, an unparseable one, or one near expiry all want a fresh mint.
        let info = config.selfCard.flatMap(IdentityCardInfo.parse(card:))
        guard info == nil || info!.needsRenewal else { return }
        guard let card = Self.createIdentityCard(nsec: nsec, name: name, suffix: suffix) else {
            return
        }
        config.selfCard = card
        persist()
    }

    // MARK: - Session lifecycle

    /// Host a clipboard session; a trusted device joins by picking this one.
    func startHosting() {
        startSession(role: .start, peerKey: nil)
    }

    /// Dial one trusted peer.
    func join(peer: TrustedPeer) {
        joinedPeer = peer.info.name
        startSession(role: .join, peerKey: peer.id)
    }

    /// Card setup: show a rotating PIN on this device and trade cards.
    func startCardHost() {
        startSession(role: .cardHost, peerKey: nil)
    }

    /// Card setup: dial the PIN shown on the other device. `canonical` comes
    /// from `normalizePIN` (the FFI re-checks it anyway). `ip` is the optional
    /// host IP for the unicast side channel where multicast is blocked; nil
    /// browses DNS-SD.
    func joinCardSetup(pin canonical: String, ip: String? = nil) {
        let ip = ip?.trimmingCharacters(in: .whitespaces)
        startSession(
            role: .cardJoin,
            peerKey: nil,
            pin: canonical,
            ip: ip?.isEmpty == false ? ip : nil
        )
    }

    private func startSession(
        role: Role,
        peerKey: String?,
        pin: String? = nil,
        ip: String? = nil
    ) {
        guard !stopping else { return } // a transition is already in flight
        lastError = nil
        incomingCard = nil
        // Only a join has a peer to name. Hosting after a join would otherwise
        // keep showing "Joining <the last peer>", which is a different session
        // to a different device. A join re-entered by `reconnect` keeps the
        // value it was given, hence the role test rather than a blanket clear.
        if role != .join {
            joinedPeer = nil
        }
        lastSession = (role, peerKey, pin, ip)
        // Instant feedback; the runtime's own status events take over once any
        // previous session has wound down off-thread.
        phase = .starting
        teardown(clearJoinedPeer: false) { [weak self] in
            guard let self else { return }
            _ = self.startRuntime(role: role, peerKey: peerKey, pin: pin, ip: ip)
        }
    }

    /// Resume after a failure. A parked session (it ended on its own but the
    /// runtime was kept alive — see `fail`) resumes on the same runtime via
    /// `duocb_reconnect`, which reuses the session identity: the same node id
    /// dials the same pinned target, so an already-paired peer accepts it
    /// without re-pairing or a fresh PIN. Only when no runtime is left does
    /// this fall back to a full restart with a fresh identity.
    func reconnect() {
        if let handle, !stopping, duocb_reconnect(handle) == 0 {
            lastError = nil
            phase = .starting
            return
        }
        guard let session = lastSession else { return }
        // A card-setup PIN is not replayable. It rotates every 60 seconds and
        // only the current and immediately previous one are accepted, so by the
        // time a failure has been read and Try again pressed, the stored PIN is
        // very likely dead — and re-dialling it produces a second failure that
        // looks like the network rather than a stale code. Back to the entry
        // screen, where the user types the PIN the other device is showing now.
        if session.role == .cardJoin {
            lastSession = nil
            stop()
            return
        }
        startSession(
            role: session.role,
            peerKey: session.peerKey,
            pin: session.pin,
            ip: session.ip
        )
    }

    /// Stop the session and return to the hub.
    func stop() {
        phase = .idle
        lastError = nil
        incomingCard = nil
        teardown {}
    }

    /// Dismiss a failure banner without reconnecting.
    func clearFailure() {
        if case .failed = phase {
            phase = .idle
        }
    }

    /// Called from scenePhase changes: on return to foreground, catch up on
    /// events immediately and detect a runtime that died while suspended.
    func noteForegrounded() {
        guard handle != nil else { return }
        tick()
        checkRuntimeAlive()
    }

    /// Build the role's config and start a runtime instance. Returns false (and
    /// records the failure) when it could not start.
    private func startRuntime(
        role: Role,
        peerKey: String?,
        pin: String?,
        ip: String?
    ) -> Bool {
        guard let selfCard = config.selfCard else {
            phase = .failed("Set up this device's identity first")
            return false
        }
        guard let irohSecret = IrohKeyStore.shared else {
            phase = .failed("could not mint this device's transport key")
            return false
        }
        var configJSON: [String: Any] = [
            "role": role.rawValue,
            "iroh_secret": irohSecret,
            "self_card": selfCard,
            "channel": config.channel.rawValue,
        ]
        if role.isCardSetup {
            // Card setup is identity-less on the wire: the private key and the
            // trusted list have no part in it, and the FFI rejects them outright
            // rather than ignoring them.
            if role == .cardJoin, let pin {
                configJSON["pin"] = pin
                // Only meaningful on a channel that uses the local network; the
                // FFI refuses the combination rather than dropping it silently.
                if let ip, !ip.isEmpty, config.channel.usesLAN {
                    configJSON["ip"] = ip
                }
            }
        } else {
            guard let identitySecret else {
                phase = .failed("Set up this device's identity first")
                return false
            }
            configJSON["identity_secret"] = identitySecret
            configJSON["peers"] = peers.map(\.card)
            if let peerKey {
                configJSON["peer_public_key"] = peerKey
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: configJSON),
              let json = String(data: data, encoding: .utf8)
        else {
            phase = .failed("could not encode config")
            return false
        }

        var err = [CChar](repeating: 0, count: DuocbBuffer.error)
        let started = json.withCString { duocb_start($0, &err, err.count) }
        guard let started else {
            phase = .failed(String(cString: err))
            return false
        }
        handle = started
        currentRole = role

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    /// Release the current instance and run `next` once it has actually shut
    /// down. `duocb_stop` performs a graceful runtime shutdown — normally fast,
    /// but up to a few seconds with a live session — so it runs off the main
    /// thread; blocking here is what would make Start/Join/Stop feel frozen.
    private func teardown(clearJoinedPeer: Bool = true, then next: @escaping () -> Void) {
        pollTimer?.invalidate()
        pollTimer = nil
        currentRole = nil
        nodeID = nil
        peerNodeID = nil
        pinDisplay = nil
        pinDeadline = nil
        hostLanIP = nil
        connPaths = nil
        pendingOutbox = nil
        if clearJoinedPeer {
            joinedPeer = nil
        }
        guard let handle else {
            next()
            return
        }
        self.handle = nil
        stopping = true
        DispatchQueue.global(qos: .userInitiated).async {
            duocb_stop(handle)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stopping = false
                next()
            }
        }
    }

    /// Surface a session failure. A failed session whose runtime is still alive
    /// is *parked*, not stopped: the runtime holds the session identity and
    /// pairing state (node id, pair claim, pinned dial target) for as long as it
    /// runs, so keeping it lets Reconnect resume the same pairing where a stop
    /// plus fresh start would mint a new identity the already-paired peer
    /// refuses. Stop, or starting anything else, still discards it. Only a
    /// runtime that actually died is torn down here.
    private func fail(_ message: String) {
        if let handle, duocb_is_running(handle) == 1 {
            phase = .failed(message)
        } else {
            phase = .failed(message)
            teardown(clearJoinedPeer: false) {}
        }
    }

    private func checkRuntimeAlive() {
        guard let handle else { return }
        if duocb_is_running(handle) == 0 {
            fail(lastError ?? "Session ended")
        }
    }

    // MARK: - Commands

    /// One in-flight send at a time, like the desktop outbox.
    var canSend: Bool { phase == .connected && pendingOutbox == nil }

    func send(text: String) {
        guard let handle, canSend, !text.isEmpty else { return }
        lastError = nil
        pendingOutbox = text
        _ = text.withCString { duocb_send_clipboard(handle, $0) }
    }

    func queryConnPath() {
        guard let handle else { return }
        _ = duocb_query_conn_path(handle)
    }

    /// Card host: mint and publish a fresh PIN immediately, invalidating every
    /// previously shown one. The replacement arrives as the next `pin_rotated`.
    func refreshPIN() {
        guard let handle else { return }
        _ = duocb_refresh_pin(handle)
    }

    func clearInbox() {
        inbox = []
    }

    func togglePeek(_ id: ClipItem.ID) {
        guard let i = inbox.firstIndex(where: { $0.id == id }) else { return }
        inbox[i].peekedAt = inbox[i].expanded ? nil : .now
    }

    // MARK: - Event pump

    private func tick() {
        drainEvents()
        tickPeeks()
    }

    private func drainEvents() {
        guard let handle else { return }
        while true {
            // Re-checked every iteration, and it must be: `apply` below can tear
            // the session down from inside this loop — a card-setup card
            // imported, or a fatal `idle` reaching `fail` — and `teardown`
            // clears `self.handle` and hands the pointer to `duocb_stop` on a
            // background queue. Reading from the captured `handle` after that is
            // a use-after-free, and it segfaults inside `duocb_next_event`
            // rather than failing gracefully. Comparing identity (not just
            // non-nil) also catches a handler that started a *new* session.
            guard self.handle == handle else { return }
            let rc = eventBuffer.withUnsafeMutableBufferPointer {
                duocb_next_event(handle, $0.baseAddress, $0.count)
            }
            if rc == -2 {
                guard eventBuffer.count < Self.maxEventBufferSize else {
                    fail("Received an event larger than the 2 MiB limit")
                    return
                }
                eventBuffer = [CChar](
                    repeating: 0,
                    count: min(eventBuffer.count * 2, Self.maxEventBufferSize)
                )
                continue
            }
            guard rc == 1 else { break }
            guard let data = String(cString: eventBuffer).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            apply(type: type, object)
        }
    }

    /// Collapse peeks that have been open longer than the timeout.
    private func tickPeeks() {
        for i in inbox.indices {
            if let at = inbox[i].peekedAt, Date.now.timeIntervalSince(at) > ClipItem.peekTimeout {
                inbox[i].peekedAt = nil
            }
        }
    }

    private func apply(type: String, _ object: [String: Any]) {
        switch type {
        case "server_ready", "client_ready":
            nodeID = object["node_id"] as? String

        case "status":
            switch object["state"] as? String {
            case "starting": phase = .starting
            case "listening": phase = .listening
            case "resolving": phase = .resolving
            case "connecting": phase = .connecting
            case "authenticating": phase = .authenticating
            case "connected":
                phase = .connected
                #if DEBUG
                if let text = autosendText {
                    autosendText = nil
                    send(text: text)
                }
                #endif
            case "reconnecting":
                phase = .reconnecting(
                    attempt: object["attempt"] as? Int ?? 0,
                    max: object["max"] as? Int ?? 0)
            case "idle":
                // Card setup goes idle the moment the cards have crossed, which
                // is success, not failure — the confirmation screen is already
                // up (peer_card_received is guaranteed to arrive first). Any
                // other idle means the session died; the preceding error event
                // carries the reason.
                if incomingCard != nil {
                    phase = .idle
                } else {
                    fail(lastError ?? "Session ended")
                }
            default: break
            }

        case "pin_rotated":
            pinDisplay = object["pin_display"] as? String
            pinDeadline = .now.addingTimeInterval(object["seconds_left"] as? Double ?? 60)
            hostLanIP = object["host_lan_ip"] as? String

        case "pin_cleared":
            pinDisplay = nil
            pinDeadline = nil
            hostLanIP = nil

        case "peer_paired":
            peerNodeID = object["peer_node_id"] as? String
            lastError = nil

        case "peer_card_received":
            // Verified as well formed and correctly signed — and nothing more.
            // Parking it here rather than storing it is the whole point: the
            // PIN is short, so only the user's pairing-code comparison can tell
            // this card from an interposer's.
            if let card = object["card"] as? String,
               let infoObject = object["info"] as? [String: Any],
               let info = IdentityCardInfo.decode(object: infoObject) {
                incomingCard = IncomingCard(card: card, info: info)
                #if DEBUG
                // E2E only: skip the screen whose entire job is the human
                // pairing-code check. Impossible in a shipping build.
                if autoTrustIncoming {
                    importIncomingCard()
                }
                #endif
            } else {
                lastError = "The other device sent a card that could not be read"
            }

        case "peer_disconnected":
            peerNodeID = nil
            connPaths = nil
            pendingOutbox = nil

        case "conn_path":
            // Only refresh an open sheet; an unsolicited snapshot shouldn't pop one.
            if connPaths != nil {
                connPaths = ConnPath.parse(object["paths"])
            }

        case "item_received":
            if let text = object["text"] as? String {
                // pulled=true is a resume re-delivery of the peer's latest sent
                // item; it may duplicate content received before the connection
                // dropped — skip it if the inbox already holds that text.
                let pulled = object["pulled"] as? Bool ?? false
                if pulled && inbox.contains(where: { $0.text == text }) {
                    break
                }
                inbox.insert(ClipItem(text: text), at: 0)
                if inbox.count > Self.maxInboxItems {
                    inbox.removeLast(inbox.count - Self.maxInboxItems)
                }
            }

        case "item_sent":
            if let text = pendingOutbox {
                outbox = ClipItem(text: text)
            }
            pendingOutbox = nil

        case "error":
            pendingOutbox = nil
            // Never cleared by an event that carries no readable message. The
            // closing `idle` reports `lastError` as the reason the session
            // died, so overwriting a real explanation with nil here would
            // replace it with the generic "Session ended".
            if let message = object["message"] as? String, !message.isEmpty {
                lastError = message
            } else if lastError == nil {
                lastError = "The session reported an error"
            }

        default:
            break
        }
    }
}
