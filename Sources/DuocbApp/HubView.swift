import SwiftUI

/// The configured home hub: this device's identity and card, the actions that
/// start a session, and the way in to card setup.
///
/// Unlike the old presence-based hub, **nothing runs here.** The trusted-device
/// list is local state read from this app's own storage — there is no broadcast,
/// no discovery, and no relay connection — so the hub holds no FFI handle at
/// all. A runtime instance appears only when the user hosts, joins, or trades
/// cards.
struct HubView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: SetupView.Step

    var body: some View {
        List {
            SessionFailureSection()
            ConfigFailureSection()
            // Only when the failure banner is not already up. `fail` passes
            // `lastError` through as the phase's message, so on a failed session
            // the two say the same sentence twice, each with its own Dismiss.
            if !isFailed, let error = controller.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                    Button("Dismiss") { controller.lastError = nil }
                        .buttonStyle(.borderless)
                }
            }
            identitySection
            actionsSection
            cardSetupSection
            Section {
                Button {
                    step = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            AppVersionSection()
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            LabeledContent("Identity") {
                Text(controller.displayIdentity ?? "")
                    .font(.system(.footnote, design: .monospaced))
            }
            if let fingerprint = controller.ownFingerprint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fingerprint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    FingerprintText(fingerprint: fingerprint)
                }
            }
            if let info = controller.selfCardInfo {
                LabeledContent("Card") {
                    Text(info.expiryText)
                        .font(.footnote)
                        .foregroundStyle(info.expired ? .orange : .secondary)
                }
            }
            if let card = controller.selfCard {
                CopyButton(value: card, title: "Copy this device's card")
            }
            ChannelBadge(channel: controller.channel)
            Button("Rename this device") { step = .name }
                .buttonStyle(.borderless)
        } header: {
            Text("This device")
        } footer: {
            Text("""
                Give another device this card and it will trust you. Cards last \
                30 days and renew themselves here, so copy a fresh one if the \
                other device says yours has expired. The fingerprint is what you \
                compare when trading cards in person.
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
            .disabled(controller.peers.isEmpty)
            Button {
                step = .join
            } label: {
                Label("Join a device", systemImage: "personalhotspot")
            }
            .disabled(controller.peers.isEmpty)
        } header: {
            Text("Share the clipboard")
        } footer: {
            if controller.peers.isEmpty {
                Text("""
                    No trusted devices yet. Trade cards with your other device \
                    below — after that, one side starts a connection and the \
                    other joins it.
                    """)
            } else {
                Text("""
                    Start makes this device host the connection; the other device \
                    joins it. Join lists the devices you trust and connects to \
                    the one that started. The join retries for a short while, so \
                    press Start on the other device if it isn't hosting yet.
                    """)
            }
        }
    }

    private var cardSetupSection: some View {
        Section {
            Button {
                step = .cardSetup
            } label: {
                Label("Trade cards", systemImage: "person.badge.key")
            }
            if !controller.peers.isEmpty {
                Button {
                    step = .join
                } label: {
                    Label(
                        "Trusted devices (\(controller.peers.count))",
                        systemImage: "checkmark.shield"
                    )
                }
            }
        } header: {
            Text("Trust")
        } footer: {
            Text("""
                Trading cards is how two devices come to trust each other: one \
                shows a PIN, the other types it, and you confirm the same \
                fingerprint appears on both screens before either card is kept. \
                It carries no clipboard content and ends as soon as the cards \
                have crossed.
                """)
        }
    }
}
