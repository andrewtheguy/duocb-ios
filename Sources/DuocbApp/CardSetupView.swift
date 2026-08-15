import SwiftUI

/// Card setup's entry screen: show a PIN on this device, or type the one shown
/// on the other.
///
/// This is the trust-bootstrap path and it never carries clipboard content. A
/// rotating PIN authenticates a short-lived connection, the two devices swap
/// signed identity cards across it, and the session ends. Which channel carries
/// the rendezvous comes from Settings and governs both devices' halves, so
/// **both must be set to a channel they share** — unlike the old quick-pair
/// PINs, the channel is not encoded in the code itself.
struct CardSetupView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: SetupView.Step

    @State private var pinDraft = ""
    @State private var ipDraft = ""
    /// How the host-IP entry is constrained to this device's subnet (locked
    /// prefix + range hint + CIDR label), read when the LAN channel is in play.
    @State private var ipContext = SessionController.JoinIPContext.empty
    /// Cached validation of `ipDraft` against `ipContext`, refreshed on edit.
    @State private var ipOutcome = SessionController.JoinIPOutcome.empty

    private var canonicalPIN: String? {
        SessionController.normalizePIN(pinDraft)
    }

    /// The manual host-IP entry only exists on a channel that uses the local
    /// network — it is the LAN half of the lookup, and the FFI refuses the
    /// combination rather than silently dropping the address.
    private var showsHostIP: Bool { controller.channel.usesLAN }

    /// The entry is optional: blank (→ browse DNS-SD) or an in-range address is
    /// ready to dial, but an out-of-range or malformed entry blocks Join.
    private var ipReady: Bool {
        switch ipOutcome {
        case .empty, .inRange: return true
        case .outOfRange, .malformed: return false
        }
    }

    /// The full IPv4 to dial, or nil to browse DNS-SD.
    private var resolvedIP: String? {
        if case .inRange(let full) = ipOutcome { return full }
        return nil
    }

    var body: some View {
        Form {
            SessionFailureSection()
            channelSection
            hostSection
            joinSection
            Section {
                Button("Back", role: .cancel) { step = .hub }
            }
        }
        // Read this device's subnet once, so the host-IP entry can lock the
        // network part and range-check the rest.
        .task(id: showsHostIP) {
            if showsHostIP {
                ipContext = SessionController.joinIPContext()
                refreshIPValidation()
            }
        }
    }

    private var channelSection: some View {
        Section {
            LabeledContent("Channel") {
                Text(controller.channel.title).font(.footnote)
            }
            Button("Change in Settings") { step = .settings }
                .buttonStyle(.borderless)
        } footer: {
            Text(controller.channel.note + "\n\nBoth devices must be set to a channel they share.")
        }
    }

    private var hostSection: some View {
        Section {
            Button {
                controller.startCardHost()
            } label: {
                Label("Show a PIN on this device", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            Text("Show a PIN")
        } footer: {
            Text("""
                A short PIN appears here and renews every 60 seconds until the \
                other device pairs. Type it on that device to trade cards.
                """)
        }
    }

    private var joinSection: some View {
        Section {
            TextField("XXXX-XXXX", text: $pinDraft)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: pinDraft) { _, value in sanitize(value) }
            if let hint = pinHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            // An optional host IP pairs over the unicast side channel when the
            // device isn't found automatically (multicast blocked). Blank
            // browses DNS-SD as usual. The entry is constrained to this device's
            // subnet — the network part is locked ahead of the field and an
            // out-of-range address is rejected.
            if showsHostIP {
                HStack(spacing: 2) {
                    if !ipContext.prefix.isEmpty {
                        Text(ipContext.prefix)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        ipContext.prefix.isEmpty ? "Host IP (optional)" : ipContext.placeholder,
                        text: $ipDraft
                    )
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: ipDraft) { _, _ in refreshIPValidation() }
                }
                if !ipContext.hint.isEmpty {
                    Text(ipContext.hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                switch ipOutcome {
                case .outOfRange:
                    Text("IP out of range for \(ipContext.label)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                case .malformed:
                    Text("Not a valid IPv4 address.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                case .empty, .inRange:
                    EmptyView()
                }
            }
            Button("Trade cards") {
                if let pin = canonicalPIN {
                    controller.joinCardSetup(pin: pin, ip: showsHostIP ? resolvedIP : nil)
                }
            }
            .disabled(canonicalPIN == nil || (showsHostIP && !ipReady))
        } header: {
            Text("Enter a PIN")
        } footer: {
            Text(showsHostIP
                ? "Type the PIN shown on the other device. If it isn't found automatically, add the local IP that device is showing."
                : "Type the PIN shown on the other device.")
        }
    }

    /// The live entry hint: neutral while the code is still being typed, a
    /// warning once it is full-length but fails its check digit (a typo).
    private var pinHint: String? {
        let progress = SessionController.pinProgress(pinDraft)
        if progress.entered == 0 { return nil }
        if progress.entered < progress.total {
            return "keep typing — \(progress.entered) of \(progress.total) characters"
        }
        return canonicalPIN == nil ? "Check the PIN — it is not valid." : nil
    }

    private func refreshIPValidation() {
        ipOutcome = SessionController.resolveJoinIP(ipDraft)
    }

    /// Keep the field to the PIN's shape, displayed as two dash-separated
    /// groups. Character filtering and the alias mapping (I/L→1, O→0) come from
    /// the Rust core, so the field can never hold something the code omits.
    private func sanitize(_ value: String) {
        let raw = SessionController.sanitizePIN(value)
        var grouped = String(raw.prefix(4))
        if raw.count > 4 {
            grouped += "-" + raw.dropFirst(4)
        }
        if grouped != pinDraft {
            pinDraft = grouped
        }
    }
}

/// Card setup in progress: the rotating PIN on the hosting device, or the dial
/// status on the joining one. Replaced by `CardConfirmView` the moment the
/// peer's card arrives.
struct CardPairingView: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        List {
            if controller.pinDisplay != nil {
                pinSection
            }
            statusSection
            if let error = controller.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Trade cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", role: .cancel) { controller.stop() }
            }
        }
    }

    private var pinSection: some View {
        Section {
            VStack(spacing: 8) {
                Text(controller.pinDisplay ?? "")
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                if let deadline = controller.pinDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let secs = max(0, Int(deadline.timeIntervalSince(context.date).rounded()))
                        Text("renews in \(secs)s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // If the other device can't find this one automatically, the
                // joiner can type this address.
                if let ip = controller.hostLanIP {
                    Text("Local IP: \(ip)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity)
            CopyButton(value: controller.pinDisplay ?? "", title: "Copy PIN", sensitive: true)
            Button {
                controller.refreshPIN()
            } label: {
                Label("New PIN", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("PIN")
        } footer: {
            Text(controller.hostLanIP == nil
                ? "Type this PIN on the other device. Renewal keeps only the current and immediately previous PIN valid; New PIN stops every earlier one working right away."
                : "Type this PIN on the other device. If it isn't found automatically, also enter the local IP shown above. Renewal keeps only the current and immediately previous PIN valid; New PIN stops every earlier one working right away.")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Circle()
                    .fill(controller.phase == .connected ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text(controller.phase.statusText)
            }
            if case .failed = controller.phase {
                Button {
                    controller.reconnect()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

/// The confirmation step, and the only thing standing between a PIN and a
/// trusted device.
///
/// The card below is verified as well-formed and correctly signed — that is all
/// the protocol can prove. A PIN is short and its rendezvous record is
/// offline-attackable, so possession of the PIN alone must never be enough to
/// become trusted; an interposer who has it would reach exactly this screen.
/// What catches them is the fingerprint: it is taken over the peer's public
/// key, and the same value is displayed on the real device, so a mismatch is
/// the tell.
struct CardConfirmView: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        List {
            if let incoming = controller.incomingCard {
                Section {
                    LabeledContent("Device") {
                        Text(incoming.info.name)
                            .font(.system(.callout, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Their fingerprint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        FingerprintText(fingerprint: incoming.info.fingerprint)
                    }
                    Text(incoming.info.expiryText)
                        .font(.caption)
                        .foregroundStyle(incoming.info.expired ? .orange : .secondary)
                } header: {
                    Text("Confirm this device")
                } footer: {
                    Text("""
                        Check that this fingerprint is exactly what the other \
                        device shows for itself. If it differs — even slightly — \
                        something is intercepting the pairing; cancel.
                        """)
                }

                if let own = controller.ownFingerprint {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your fingerprint")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            FingerprintText(fingerprint: own)
                        }
                    } footer: {
                        Text("The other device is showing this value for you; it should match there.")
                    }
                }

                Section {
                    Button {
                        controller.importIncomingCard()
                    } label: {
                        Label("Fingerprints match — trust this device", systemImage: "checkmark.shield")
                    }
                    Button("Cancel", role: .destructive) {
                        controller.dismissIncomingCard()
                    }
                }
            }
        }
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension SessionController.Phase {
    /// Phase → user copy, mirroring the desktop's status_text().
    var statusText: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Waiting for the other device…"
        case .resolving: "Looking for the other device…"
        case .connecting: "Connecting…"
        case .authenticating: "Authenticating…"
        case .connected: "Connected"
        case .reconnecting(let attempt, let max): "Reconnecting… (attempt \(attempt) of \(max))"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
