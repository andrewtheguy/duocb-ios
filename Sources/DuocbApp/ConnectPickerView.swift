import SwiftUI
import UIKit

/// The trusted-device picker: every device whose card this one holds. Tap one
/// to connect to it — the person on that device taps this one, and the core
/// works out which of the two listens.
///
/// The list is purely local — these are stored cards, not discovered devices —
/// so there is no refresh, no "last seen", and no online/offline verdict.
/// Starting the session is the liveness check, exactly as on the desktop.
struct ConnectPickerView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: SetupView.Step

    @State private var showImport = false
    @State private var importDraft = ""
    @State private var importError: String?
    @State private var pendingRemoval: TrustedPeer?
    /// The pasted card decoded, or nil while it is empty or invalid. Cached
    /// rather than recomputed in `body`: decoding verifies the card's signature,
    /// and `body` is evaluated on every keystroke and reads it more than once.
    @State private var preview: IdentityCardInfo?

    var body: some View {
        List {
            devicesSection
            importSection
            Section {
                Button("Back", role: .cancel) { step = .hub }
            }
        }
        .confirmationDialog(
            pendingRemoval.map { "Stop trusting \($0.info.name)?" } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop trusting", role: .destructive) {
                if let peer = pendingRemoval {
                    controller.removePeer(publicKey: peer.id)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("""
                This device will no longer connect to it. The other device keeps \
                your card until it removes it too. To pair again you have to \
                trade cards.
                """)
        }
    }

    private var devicesSection: some View {
        Section {
            if controller.peers.isEmpty {
                Text("""
                    No trusted devices yet. Trade cards with your other device, \
                    or paste its card below.
                    """)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            ForEach(controller.peers) { peer in
                Button {
                    controller.connect(peer: peer)
                } label: {
                    peerRow(peer)
                }
                .swipeActions(edge: .trailing) {
                    Button("Remove", role: .destructive) { pendingRemoval = peer }
                }
            }
        } header: {
            Text("Trusted devices")
        } footer: {
            Text("""
                Tap a device to connect to it, and tap this one over there — the \
                order does not matter, and whoever is ready first waits. Swipe a \
                row to stop trusting it. An expired card can no longer pair — ask \
                that device for a fresh one, or trade cards again.
                """)
        }
    }

    private func peerRow(_ peer: TrustedPeer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.info.name)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                // Kept out of the name line so a date never wraps mid-identity,
                // and coloured because lapsed trust is a problem, not a detail.
                Text(peer.info.expiryText)
                    .font(.caption)
                    .foregroundStyle(peer.info.expired ? .orange : .secondary)
            }
            Spacer()
            Text("Connect")
                .font(.callout)
                .foregroundStyle(.tint)
        }
    }

    /// Paste-import, the copy-and-paste half of trust bootstrapping — the same
    /// path the desktop offers, for when the two devices *do* have a way to move
    /// text between them and a PIN session would be ceremony.
    private var importSection: some View {
        Section {
            if showImport {
                TextField("Paste the other device's card", text: $importDraft, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(2...6)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: importDraft, initial: true) { _, draft in
                        importError = nil
                        preview = Self.decode(draft)
                    }
                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if let info = preview {
                    LabeledContent("Device") {
                        Text(info.name).font(.system(.footnote, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        FingerprintText(fingerprint: info.fingerprint)
                    }
                    Text(info.expiryText)
                        .font(.caption)
                        .foregroundStyle(info.expired ? .orange : .secondary)
                }
                // Read at tap time, never gated on `hasStrings`: SwiftUI does not
                // re-render when the pasteboard changes, so a button disabled at
                // first render stays disabled after the user copies the card.
                Button("Paste") {
                    let pasted = (UIPasteboard.general.string ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if pasted.isEmpty {
                        importError = "The clipboard is empty"
                    } else {
                        importDraft = pasted
                    }
                }
                Button("Trust this device") {
                    if let error = controller.importPeerCard(importDraft) {
                        importError = error
                    } else {
                        importDraft = ""
                        showImport = false
                    }
                }
                // An expired card is refused by the import itself (it records
                // trust that can never pair), and the expiry line above says so.
                .disabled(preview == nil)
                Button("Cancel", role: .cancel) {
                    importDraft = ""
                    importError = nil
                    showImport = false
                }
            } else {
                Button {
                    showImport = true
                } label: {
                    Label("Paste a card", systemImage: "doc.on.clipboard")
                }
            }
        } footer: {
            if showImport {
                Text("""
                    Check the fingerprint above matches the one shown on that \
                    device before trusting it — that comparison is the only thing \
                    standing between you and trusting the wrong device.
                    """)
            }
        }
    }

    /// Decode a pasted card for the preview, or nil while it is empty or
    /// invalid. Verifies the signature, so it is called on edit, not in `body`.
    private static func decode(_ draft: String) -> IdentityCardInfo? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return IdentityCardInfo.parse(card: trimmed)
    }
}
