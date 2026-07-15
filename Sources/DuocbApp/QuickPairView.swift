import SwiftUI

/// Quick pair (the desktop "P" and "L" presets): ephemeral pairing with any
/// duocb device via a short rotating PIN — no shared secret, name, or
/// identity involved, so it also works before setup. Hosting moves to
/// SessionView, which shows the PIN; joining dials the PIN typed here. The
/// channel menu picks the rendezvous for the PIN you *show* — the default
/// internet+LAN one or the LAN-only one (Bonjour through the system daemon, no
/// third-party server). When joining, the channel is read from the typed PIN,
/// so there is nothing to match.
struct QuickPairView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: ConfigureView.Step
    @State private var draft = ""
    @State private var ipDraft = ""
    @State private var channel: SessionController.QuickChannel = .nostrLan
    /// How the host-IP entry is constrained to this device's subnet (locked
    /// prefix + range hint + CIDR label), fetched when a LAN-only PIN is typed.
    @State private var ipContext = SessionController.JoinIPContext.empty
    /// Cached validation of `ipDraft` against `ipContext`, refreshed on edit.
    @State private var ipOutcome = SessionController.JoinIPOutcome.empty

    private var canonicalPIN: String? {
        SessionController.normalizePIN(draft)
    }

    /// A complete, valid LAN-only PIN reveals the optional host-IP field (the
    /// FFI reads the channel from the PIN, so this mirrors that classification).
    private var isLanOnly: Bool {
        SessionController.pinIsLanOnly(draft)
    }

    /// The host-IP entry is optional; blank (→ mDNS) or an in-range address is
    /// ready to dial, but an out-of-range or malformed entry blocks Join.
    private var ipReady: Bool {
        switch ipOutcome {
        case .empty, .inRange: return true
        case .outOfRange, .malformed: return false
        }
    }

    /// The full IPv4 to dial, or nil to resolve via mDNS.
    private var resolvedIP: String? {
        if case .inRange(let full) = ipOutcome { return full }
        return nil
    }

    private func refreshIPValidation() {
        ipOutcome = SessionController.resolveJoinIP(ipDraft)
    }

    var body: some View {
        Form {
            SessionFailureSection()
            hostSection
            joinSection
            Section {
                Button("Back", role: .cancel) {
                    step = controller.hasIdentity ? .hub : .choice
                }
            }
        }
        // Read this device's subnet once a LAN-only PIN reveals the host-IP
        // field, so the entry can lock the network part and range-check the rest.
        .task(id: isLanOnly) {
            if isLanOnly {
                ipContext = SessionController.joinIPContext()
                refreshIPValidation()
            }
        }
    }

    // Showing a PIN is where the channel is chosen; the picker lives here so the
    // join section below has no choices to make.
    private var hostSection: some View {
        Section {
            Picker(selection: $channel) {
                Text("Internet + local network")
                    .tag(SessionController.QuickChannel.nostrLan)
                Text("Local network only")
                    .tag(SessionController.QuickChannel.lan)
            } label: {
                Label("Channel", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Button {
                controller.startQuickHost(channel: channel)
            } label: {
                Label("Show a PIN on this device", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            Text("Show a PIN")
        } footer: {
            if channel == .lan {
                Text("""
                    No third-party server: the PIN is found over the local \
                    network only (the desktop "L" preset); both devices must be \
                    on the same network, and joining asks for Local Network \
                    permission. A short PIN appears on this device and renews \
                    every 60 seconds until a device pairs.
                    """)
            } else {
                Text("""
                    Works across the internet and on the same network (the \
                    desktop "P" preset). A short PIN appears on this device and \
                    renews every 60 seconds until a device pairs.
                    """)
            }
        }
    }

    private var joinSection: some View {
        Section {
            TextField("XXXX-XXXX", text: $draft)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: draft) { _, value in
                    sanitize(value)
                }
            if rawPINLength == 8 && canonicalPIN == nil {
                Text("Check the PIN — it is not valid.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            // LAN-only PIN: an optional host IP pairs over the unicast side
            // channel when the device isn't found automatically (multicast
            // blocked). Blank resolves via mDNS as usual. The entry is
            // constrained to this device's subnet — the network part is locked
            // ahead of the field and an out-of-range address is rejected.
            if isLanOnly {
                HStack(spacing: 2) {
                    if !ipContext.prefix.isEmpty {
                        Text(ipContext.prefix)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    TextField(ipContext.prefix.isEmpty ? "Host IP (optional)" : ipContext.placeholder,
                              text: $ipDraft)
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
            Button("Join") {
                if let pin = canonicalPIN {
                    controller.joinQuick(pin: pin, ip: isLanOnly ? resolvedIP : nil)
                }
            }
            .disabled(canonicalPIN == nil || (isLanOnly && !ipReady))
        } header: {
            Text("Enter a PIN")
        } footer: {
            Text("Type the PIN shown on the hosting device — its channel is taken from the PIN automatically. For a local-network PIN you can add the host's IP if it isn't found automatically.")
        }
    }

    private var rawPINLength: Int {
        draft.filter { $0 != "-" }.count
    }

    /// Keep the field to the PIN's shape: uppercase, letters and digits only,
    /// at most 8 characters, displayed as two dash-separated groups. Alias
    /// mapping (I/L→1, O→0) and the check digit stay in the Rust core.
    private func sanitize(_ value: String) {
        let raw = value.uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .prefix(8)
        var grouped = String(raw.prefix(4))
        if raw.count > 4 {
            grouped += "-" + raw.dropFirst(4)
        }
        if grouped != draft {
            draft = grouped
        }
    }
}
