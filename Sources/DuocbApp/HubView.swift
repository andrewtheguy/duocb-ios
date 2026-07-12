import SwiftUI

/// The configured home hub: this device's identity and the two actions —
/// **Start a connection** (host; needs nothing but this device) or **Join
/// another device**, which opens the device picker (JoinView). While this
/// screen is up, a hub runtime instance broadcasts presence; the peer list is
/// only fetched while the picker is visible.
struct HubView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: ConfigureView.Step
    @State private var confirmClearSecret = false

    var body: some View {
        List {
            failureSections
            identitySection
            actionsSection
        }
        .onAppear { controller.startHub() }
        .confirmationDialog(
            "Clear the shared secret?",
            isPresented: $confirmClearSecret,
            titleVisibility: .visible
        ) {
            Button("Clear secret", role: .destructive) {
                controller.clearSecret()
                step = .choice
            }
        } message: {
            Text("""
                This device will stop broadcasting and can no longer pair with \
                your other devices until a secret is set up again. The device's \
                permanent id is kept.
                """)
        }
    }

    // MARK: - Sections

    /// A failed session (with Reconnect) and hub trouble, when present.
    @ViewBuilder
    private var failureSections: some View {
        if case .failed(let message) = controller.phase {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
                HStack {
                    if controller.lastSession != nil {
                        Button("Reconnect") { controller.reconnect() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("Dismiss") { controller.clearFailure() }
                        .buttonStyle(.borderless)
                }
            }
        }
        if let hubError = controller.hubError {
            Section {
                Label(hubError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                Button("Retry") { controller.retryHub() }
                    .buttonStyle(.borderless)
            }
        }
        if let conflict = controller.presenceConflict {
            Section {
                Label(conflict, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        }
    }

    private var identitySection: some View {
        Section {
            LabeledContent("Identity") {
                Text(controller.displayIdentity ?? "")
                    .font(.system(.footnote, design: .monospaced))
            }
            if let secret = controller.secret {
                LabeledContent("Secret") {
                    Text(SessionController.maskedSecretHint(secret))
                        .font(.system(.footnote, design: .monospaced))
                }
                if let fingerprint = SessionController.tokenFingerprint(secret) {
                    LabeledContent("Fingerprint") {
                        Text(fingerprint)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
                CopySecretButton(secret: secret)
            }
            Button("Rename this device") { step = .name }
                .buttonStyle(.borderless)
            Button("Clear secret…", role: .destructive) { confirmClearSecret = true }
                .buttonStyle(.borderless)
        } header: {
            Text("This device")
        } footer: {
            Text("""
                The fingerprint must match on every device. Copy the secret to \
                paste it into the setup on your next device.
                """)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                controller.startHosting()
            } label: {
                Label("Start a connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            Button {
                step = .join
            } label: {
                Label("Join another device", systemImage: "personalhotspot")
            }
        } header: {
            Text("Pair")
        } footer: {
            Text("""
                Start makes this device host the connection — the other device \
                joins it. Join shows your other devices and connects to the one \
                that started.
                """)
        }
    }
}

/// The device picker: the list of your other devices, shown only when the
/// user chose Join. Tap a hosting device to connect to it. The list refreshes
/// on entry, by pull, and every 30 s while visible.
struct JoinView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: ConfigureView.Step

    var body: some View {
        List {
            if let hubError = controller.hubError {
                Section {
                    Label(hubError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                    Button("Retry") { controller.retryHub() }
                        .buttonStyle(.borderless)
                }
            }
            devicesSection
            Section {
                Button("Back", role: .cancel) { step = .hub }
            }
        }
        .refreshable { controller.refreshPeers() }
        .onAppear {
            // The picker may be reached with no hub running yet (e.g. straight
            // after a session ended); make sure presence + fetching are up.
            controller.startHub()
            controller.setPeerListVisible(true)
        }
        .onDisappear { controller.setPeerListVisible(false) }
    }

    private var devicesSection: some View {
        Section {
            if controller.peers.isEmpty {
                Text(controller.peersRefreshedAt == nil
                    ? "Looking for your other devices…"
                    : "No other devices found yet. Import the same secret on your other device and it will appear here.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            ForEach(controller.peers) { peer in
                Button {
                    controller.join(peerDisplay: peer.display)
                } label: {
                    peerRow(peer)
                }
            }
        } header: {
            HStack {
                Text("Your devices")
                Spacer()
                if let at = controller.peersRefreshedAt {
                    (Text("updated ") + Text(at, style: .relative) + Text(" ago"))
                        .textCase(nil)
                }
            }
        } footer: {
            Text("""
                Tap a device to join it. If it isn't hosting yet, press Start \
                there — the join keeps retrying until it is. Pull down to \
                refresh.
                """)
        }
    }

    private func peerRow(_ peer: PeerInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.display)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(peerSubtitle(peer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Join")
                .font(.callout)
                .foregroundStyle(.tint)
        }
    }

    /// The record's age, not an online/offline verdict — relay timing is too
    /// unreliable for one, and joining never requires it.
    private func peerSubtitle(_ peer: PeerInfo) -> String {
        var parts: [String] = []
        if peer.hosting {
            parts.append("hosting")
        }
        parts.append("seen \(peer.lastSeenText)")
        return parts.joined(separator: " · ")
    }
}
