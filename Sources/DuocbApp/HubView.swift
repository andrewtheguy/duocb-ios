import SwiftUI

/// The configured home hub: this device's identity and card, the actions that
/// start a session, and the way in to card setup.
///
/// **Nothing runs here.** The trusted-device
/// list is local state read from this app's own storage — there is no broadcast,
/// no discovery, and no relay connection — so the hub holds no FFI handle at
/// all. A runtime instance appears only when the user connects to a device or
/// trades cards.
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
                30 days; at launch, this device renews its card once less than \
                seven days remain. Copy a fresh one if the other device says \
                yours has expired. Your private key never \
                expires — a renewal is the same key signing a new card. The \
                fingerprint is this device's half of the pairing code shown when \
                trading cards, and it does not change when the card renews.
                """)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                step = .connect
            } label: {
                Label("Connect to a device", systemImage: "personalhotspot")
            }
            .disabled(controller.peers.isEmpty)
        } header: {
            Text("Share the clipboard")
        } footer: {
            if controller.peers.isEmpty {
                Text("""
                    No trusted devices yet. Trade cards with your other device \
                    below — after that, each of you picks the other and presses \
                    Connect.
                    """)
            } else {
                Text("""
                    Pick the device you want to share with, and have it pick this \
                    one. Neither side has to go first or agree who hosts — duocb \
                    settles that from the two identity keys, and whoever is ready \
                    first waits for the other.
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
                    step = .connect
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
                shows a PIN, the other types it, and you check that one pairing \
                code reads identically on both screens before either card is \
                kept. It carries no clipboard content and ends as soon as the \
                cards have crossed.
                """)
        }
    }
}
