import Foundation
import Observation

/// Central view model: owns the Rust FFI handle, polls its event queue on a
/// timer, and mirrors the desktop app's session state machine.
///
/// The Rust side runs its own embedded tokio runtime (see ../duocb
/// crates/duocb-ffi); Swift drives it with synchronous C calls and drains
/// JSON events via `duocb_next_event`. Persistence mirrors the desktop policy:
/// the start role saves the token to the Keychain *before* starting, the join
/// role only after the first successful pairing (`peer_paired`), so a failed
/// join never overwrites a good token.
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

    enum Role: String, CaseIterable, Identifiable {
        case start, join
        var id: String { rawValue }
    }

    private(set) var phase: Phase = .idle
    private(set) var nodeID: String?
    private(set) var tokenFingerprint: String?
    private(set) var peerNodeID: String?
    /// Non-nil while the connection-path sheet is up; refreshed by queryConnPath.
    var connPaths: [ConnPath]?
    /// Received items, newest first, capped like the desktop inbox.
    private(set) var inbox: [ClipItem] = []
    /// The last successfully sent item.
    private(set) var outbox: ClipItem?
    /// Last error message, shown as a banner; errors are not always fatal.
    var lastError: String?

    /// Max retained inbox items (matches desktop MAX_INBOX_ITEMS).
    private static let maxInboxItems = 5

    private var handle: OpaquePointer?
    private var pollTimer: Timer?
    /// The one in-flight send (desktop parity: one outbox slot), promoted to
    /// `outbox` when the runtime confirms with `item_sent`.
    private var pendingOutbox: String?
    /// Settings of the last start, for join-role persistence and Reconnect.
    private(set) var lastSettings: (role: Role, token: String, name: String)?

    var isSessionActive: Bool { handle != nil }

    init() {
        duocb_init_logging()
    }

    #if DEBUG
    /// Text queued by autostartFromEnvironment, sent once connected.
    private var autosendText: String?

    /// E2E-test hook (Simulator/Debug only): start a session straight from
    /// launch environment variables so a test harness can drive pairing
    /// without UI automation. Pass via `xcrun simctl launch` with
    /// SIMCTL_CHILD_DUOCB_AUTOSTART_{TOKEN,ROLE,NAME,SEND}.
    func autostartFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard handle == nil,
              let token = env["DUOCB_AUTOSTART_TOKEN"],
              let role = Role(rawValue: env["DUOCB_AUTOSTART_ROLE"] ?? "join")
        else { return }
        autosendText = env["DUOCB_AUTOSTART_SEND"]
        start(role: role, token: token, name: env["DUOCB_AUTOSTART_NAME"] ?? "phone")
    }
    #endif

    // MARK: - Token helpers (thin wrappers over the FFI)

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

    // MARK: - Session lifecycle

    func start(role: Role, token: String, name: String) {
        stop()
        lastError = nil
        lastSettings = (role, token, name)

        // Desktop parity: the initiator persists the token before starting;
        // the connector persists only after peer_paired (see apply(event:)).
        if role == .start {
            TokenStore.save(token)
        }

        let config: [String: Any] = ["role": role.rawValue, "token": token, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8)
        else {
            phase = .failed("could not encode config")
            return
        }

        var err = [CChar](repeating: 0, count: 1024)
        let started = json.withCString { duocb_start($0, &err, err.count) }
        guard let started else {
            phase = .failed(String(cString: err))
            return
        }
        handle = started
        phase = .starting

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stop the session and return to the setup screen.
    func stop() {
        teardown()
        phase = .idle
        lastError = nil
    }

    /// Re-run the last start after a failure.
    func reconnect() {
        guard let s = lastSettings else { return }
        start(role: s.role, token: s.token, name: s.name)
    }

    /// Called from scenePhase changes: on return to foreground, catch up on
    /// events immediately and detect a runtime that died while suspended.
    func noteForegrounded() {
        guard handle != nil else { return }
        tick()
        checkRuntimeAlive()
    }

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let handle {
            duocb_stop(handle)
            self.handle = nil
        }
        nodeID = nil
        tokenFingerprint = nil
        peerNodeID = nil
        connPaths = nil
        pendingOutbox = nil
    }

    /// Mark the session dead (runtime ended on its own) and free the handle,
    /// keeping the failure visible.
    private func fail(_ message: String) {
        teardown()
        phase = .failed(message)
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
    }

    private func drainEvents() {
        guard let handle else { return }
        // Clip items cap at 1 MiB on the wire; 2 MiB always fits the JSON.
        var buf = [CChar](repeating: 0, count: 2 * 1024 * 1024)
        while true {
            let rc = duocb_next_event(handle, &buf, buf.count)
            if rc == -2 {
                buf = [CChar](repeating: 0, count: buf.count * 2)
                continue
            }
            guard rc == 1 else { break }
            guard let data = String(cString: buf).data(using: .utf8),
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
            // Desktop parity: the connector persists the token only once a
            // pairing actually succeeded.
            if lastSettings?.role == .join, let token = lastSettings?.token {
                TokenStore.save(token)
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
            lastError = object["message"] as? String

        default:
            break
        }
    }
}
