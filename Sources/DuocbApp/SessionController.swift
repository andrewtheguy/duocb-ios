import Foundation
import Observation

/// Central view model: owns the Rust FFI handle, polls its event queue on a
/// timer, and mirrors the desktop app's configure-mode state machine.
///
/// Two kinds of runtime instance exist, at most one at a time:
/// - a **hub** instance (role "hub") runs while the device list is on screen:
///   it broadcasts this device's presence and fetches the peer list, but never
///   opens a session;
/// - a **session** instance (role "start"/"join") hosts a connection or joins
///   the hosting device picked from the list.
/// Moving between them stops the current instance and starts a fresh one, as
/// the FFI prescribes.
///
/// Identity persistence mirrors the desktop wizard: the secret is saved to the
/// Keychain the moment it is generated or imported, the name to UserDefaults
/// the moment it is confirmed, and the permanent suffix is minted once on
/// first launch (Keychain) and never regenerated — it survives clearing the
/// secret.
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
        case reconnecting(backoffSecs: Int)
        case failed(String)
    }

    enum Role: String {
        case hub, start, join
    }

    // MARK: - Session state

    private(set) var phase: Phase = .idle
    private(set) var nodeID: String?
    private(set) var tokenFingerprint: String?
    private(set) var peerNodeID: String?
    /// Join role: the display identity of the device being joined.
    private(set) var joinedPeer: String?
    /// Non-nil while the connection-path sheet is up; refreshed by queryConnPath.
    var connPaths: [ConnPath]?
    /// Received items, newest first, capped like the desktop inbox.
    private(set) var inbox: [ClipItem] = []
    /// The last successfully sent item.
    private(set) var outbox: ClipItem?
    /// Last error message, shown as a banner; errors are not always fatal.
    var lastError: String?

    // MARK: - Identity (configure-mode standing state)

    /// The standing secret shared by all of this person's devices, or nil
    /// until the setup wizard runs. Backed by the Keychain (TokenStore).
    private(set) var secret: String? = TokenStore.load()
    /// This device's short name, or nil until confirmed in the wizard. Kept
    /// (as a wizard prefill) when the secret is cleared.
    private(set) var deviceName: String? = {
        let name = UserDefaults.standard.string(forKey: SessionController.myNameKey)
        return (name?.isEmpty ?? true) ? nil : name
    }()
    /// This device's permanent identity suffix, minted on first launch.
    let suffix: String = SuffixStore.loadOrCreate()

    // MARK: - Hub state

    /// The other devices sharing the secret, from the last `peer_list` event.
    private(set) var peers: [PeerInfo] = []
    private(set) var peersRefreshedAt: Date?
    /// Another live process broadcasts as this device; broadcasting stopped.
    private(set) var presenceConflict: String?
    /// A failure of the hub instance itself (start error, peer-fetch error).
    private(set) var hubError: String?

    /// UserDefaults key for this device's saved name.
    static let myNameKey = "myName"

    /// Max retained inbox items (matches desktop MAX_INBOX_ITEMS).
    private static let maxInboxItems = 5
    /// The FFI contract guarantees that every JSON event fits in 2 MiB.
    private static let maxEventBufferSize = 2 * 1024 * 1024
    /// Hub auto-refresh cadence (desktop parity: PEER_REFRESH_INTERVAL).
    private static let peerRefreshInterval: TimeInterval = 30

    private var handle: OpaquePointer?
    private var currentRole: Role?
    private var pollTimer: Timer?
    private var eventBuffer = [CChar](repeating: 0, count: 64 * 1024)
    /// The one in-flight send (desktop parity: one outbox slot), promoted to
    /// `outbox` when the runtime confirms with `item_sent`.
    private var pendingOutbox: String?
    /// When the last peer fetch was requested (auto-refresh throttle).
    private var lastPeerRequestAt: Date?
    /// Whether the device picker (JoinView) is on screen; the peer list is
    /// only kept fresh while it is.
    private var peerListVisible = false
    /// The last session start, for Reconnect after a failure.
    private(set) var lastSession: (role: Role, peer: String?)?

    var isSessionActive: Bool { handle != nil && currentRole != .hub }
    var hasIdentity: Bool { secret != nil && deviceName != nil }
    /// The identity broadcast to the other devices, e.g. "phone_a7B2c3D4".
    var displayIdentity: String? { deviceName.map { "\($0)_\(suffix)" } }

    init() {
        duocb_init_logging()
    }

    #if DEBUG
    /// Text queued by autostartFromEnvironment, sent once connected.
    private var autosendText: String?

    /// E2E-test hook (Simulator/Debug only): set up the identity and start a
    /// session straight from launch environment variables so a test harness
    /// can drive pairing without UI automation. Pass via `xcrun simctl launch`
    /// with SIMCTL_CHILD_DUOCB_AUTOSTART_{TOKEN,NAME,ROLE,PEER,SEND};
    /// ROLE=join requires PEER (the target's display identity), and omitting
    /// ROLE lands on the hub with the identity configured.
    func autostartFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard !isSessionActive, let token = env["DUOCB_AUTOSTART_TOKEN"] else { return }
        autosendText = env["DUOCB_AUTOSTART_SEND"]
        setSecret(token)
        saveName(env["DUOCB_AUTOSTART_NAME"] ?? "phone")
        switch env["DUOCB_AUTOSTART_ROLE"] {
        case "start":
            startHosting()
        case "join":
            if let peer = env["DUOCB_AUTOSTART_PEER"] {
                join(peerDisplay: peer)
            }
        default:
            break
        }
    }
    #endif

    // MARK: - Token and identity helpers (thin wrappers over the FFI)

    nonisolated static func generateToken() -> String {
        var buf = [CChar](repeating: 0, count: 64)
        guard duocb_generate_token(&buf, buf.count) == 1 else { return "" }
        return String(cString: buf)
    }

    /// nil if valid, else the reason.
    nonisolated static func validateToken(_ token: String) -> String? {
        var err = [CChar](repeating: 0, count: 256)
        let rc = token.withCString { duocb_validate_token($0, &err, err.count) }
        switch rc {
        case 1: return nil
        case 0: return String(cString: err)
        default: return "invalid token"
        }
    }

    nonisolated static func tokenFingerprint(_ token: String) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        let rc = token.withCString { duocb_token_fingerprint($0, &buf, buf.count) }
        return rc == 1 ? String(cString: buf) : nil
    }

    /// Asterisks plus the secret's last four characters — never the whole
    /// value, but enough of a hint to spot-check that a paste into a place
    /// without fingerprint support took the right one (desktop parity).
    nonisolated static func maskedSecretHint(_ secret: String) -> String {
        "********" + secret.suffix(4)
    }

    /// nil if valid, else the reason (mirrors duocb-core identity::validate_name).
    nonisolated static func validateName(_ name: String) -> String? {
        if name.isEmpty {
            return "enter a name"
        }
        if name.count > 24 {
            return "keep the name to 24 characters or fewer"
        }
        if !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            return "letters, digits, and '-' only"
        }
        return nil
    }

    // MARK: - Identity mutation (wizard commit points)

    /// Persist a newly generated or imported secret. Saved immediately, like
    /// the desktop wizard.
    func setSecret(_ token: String) {
        TokenStore.save(token)
        secret = token
    }

    /// Persist the confirmed device name. If the hub is broadcasting, restart
    /// it so the presence record carries the new name.
    func saveName(_ name: String) {
        UserDefaults.standard.set(name, forKey: Self.myNameKey)
        deviceName = name
        if currentRole == .hub {
            teardown()
            startHub()
        }
    }

    /// Clear the standing secret (an explicit, confirmed action). The suffix
    /// is permanent and the name is kept as a prefill for the next setup.
    func clearSecret() {
        if currentRole == .hub {
            teardown()
        }
        TokenStore.clear()
        secret = nil
        peers = []
        peersRefreshedAt = nil
        lastPeerRequestAt = nil
        presenceConflict = nil
        hubError = nil
        lastSession = nil
    }

    // MARK: - Hub lifecycle

    /// Run the hub instance (presence broadcast + peer list) while the hub
    /// screen is visible. No-op when any instance is already running.
    func startHub() {
        guard handle == nil, hasIdentity else { return }
        presenceConflict = nil
        hubError = nil
        guard startRuntime(role: .hub, peer: nil) else { return }
        // The FFI issues the initial peer fetch itself.
        lastPeerRequestAt = .now
    }

    /// Re-fetch the device list; the result arrives as a `peer_list` event.
    func refreshPeers() {
        guard let handle else { return }
        lastPeerRequestAt = .now
        _ = duocb_refresh_peers(handle)
    }

    /// Track whether the device picker is on screen. Entering it refreshes
    /// the list right away (unless a fetch just went out); leaving it stops
    /// the 30 s auto-refresh.
    func setPeerListVisible(_ visible: Bool) {
        peerListVisible = visible
        if visible, currentRole == .hub,
           Date.now.timeIntervalSince(lastPeerRequestAt ?? .distantPast) > 5 {
            refreshPeers()
        }
    }

    /// Recover from a hub failure: restart the hub if it died, otherwise just
    /// retry the peer fetch.
    func retryHub() {
        hubError = nil
        if handle == nil {
            startHub()
        } else {
            refreshPeers()
        }
    }

    // MARK: - Session lifecycle

    /// Host a connection; the other device joins by picking this one from its
    /// list.
    func startHosting() {
        startSession(role: .start, peer: nil)
    }

    /// Join the hosting device picked from the peer list.
    func join(peerDisplay: String) {
        startSession(role: .join, peer: peerDisplay)
    }

    private func startSession(role: Role, peer: String?) {
        teardown() // stops the hub (or a previous session)
        phase = .idle
        lastError = nil
        lastSession = (role, peer)
        guard startRuntime(role: role, peer: peer) else { return }
        phase = .starting
    }

    /// Re-run the last session after a failure (offered on the hub).
    func reconnect() {
        guard let s = lastSession else { return }
        startSession(role: s.role, peer: s.peer)
    }

    /// Stop the session and return to the hub.
    func stop() {
        teardown()
        phase = .idle
        lastError = nil
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

    /// Start a runtime instance with the stored identity. Returns false (and
    /// records the failure) when it could not start.
    private func startRuntime(role: Role, peer: String?) -> Bool {
        guard let secret, let deviceName else {
            record(failure: "Set up the secret and device name first", for: role)
            return false
        }
        var config: [String: Any] = [
            "role": role.rawValue,
            "token": secret,
            "name": deviceName,
            "suffix": suffix,
        ]
        if let peer {
            config["peer"] = peer
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8)
        else {
            record(failure: "could not encode config", for: role)
            return false
        }

        var err = [CChar](repeating: 0, count: 1024)
        let started = json.withCString { duocb_start($0, &err, err.count) }
        guard let started else {
            record(failure: String(cString: err), for: role)
            return false
        }
        handle = started
        currentRole = role
        joinedPeer = role == .join ? peer : nil

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    private func record(failure: String, for role: Role) {
        if role == .hub {
            hubError = failure
        } else {
            phase = .failed(failure)
        }
    }

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let handle {
            duocb_stop(handle)
            self.handle = nil
        }
        currentRole = nil
        nodeID = nil
        tokenFingerprint = nil
        peerNodeID = nil
        joinedPeer = nil
        connPaths = nil
        pendingOutbox = nil
    }

    /// Mark the current instance dead (runtime ended on its own) and free the
    /// handle, keeping the failure visible on the right screen.
    private func fail(_ message: String) {
        let wasHub = currentRole == .hub
        teardown()
        if wasHub {
            hubError = message
        } else {
            phase = .failed(message)
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
        pendingOutbox = text
        _ = text.withCString { duocb_send_clipboard(handle, $0) }
    }

    func queryConnPath() {
        guard let handle else { return }
        _ = duocb_query_conn_path(handle)
    }

    func togglePeek(_ id: ClipItem.ID) {
        guard let i = inbox.firstIndex(where: { $0.id == id }) else { return }
        inbox[i].peekedAt = inbox[i].expanded ? nil : .now
    }

    // MARK: - Event pump

    private func tick() {
        drainEvents()
        tickPeeks()
        autoRefreshPeers()
    }

    /// While the device picker is on screen, keep the list fresh (desktop
    /// parity: refresh every 30 s while visible).
    private func autoRefreshPeers() {
        guard currentRole == .hub, handle != nil, peerListVisible,
              Date.now.timeIntervalSince(lastPeerRequestAt ?? .distantPast) > Self.peerRefreshInterval
        else { return }
        refreshPeers()
    }

    private func drainEvents() {
        guard let handle else { return }
        while true {
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
            tokenFingerprint = object["token_fingerprint"] as? String

        case "status":
            // The hub never runs a session; ignore stray status chatter there.
            guard currentRole != .hub else { break }
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
                phase = .reconnecting(backoffSecs: object["backoff_secs"] as? Int ?? 0)
            case "idle":
                // The runtime only goes idle on its own when the session died
                // (fatal auth failure, client gave up). The preceding error
                // event carries the reason.
                fail(lastError ?? "Session ended")
            default: break
            }

        case "peer_paired":
            peerNodeID = object["peer_node_id"] as? String
            lastError = nil

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

        case "peer_list":
            peers = PeerInfo.parse(object["peers"])
            peersRefreshedAt = .now
            hubError = nil

        case "presence_conflict":
            presenceConflict = object["message"] as? String

        case "error":
            pendingOutbox = nil
            if currentRole == .hub {
                hubError = object["message"] as? String
            } else {
                lastError = object["message"] as? String
            }

        default:
            break
        }
    }
}
