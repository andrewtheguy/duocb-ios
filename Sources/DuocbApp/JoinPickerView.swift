import SwiftUI
import UIKit

/// The trusted-device picker: every device whose card this one holds. Tap one
/// to join the session it is hosting.
///
/// The list is purely local — these are stored cards, not discovered devices —
/// so there is no refresh, no "last seen", and no online/offline verdict. The
/// dial is the liveness check, exactly as on the desktop.
struct JoinPickerView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: SetupView.Step

    @State private var showImport = false
    @State private var importDraft = ""
    @State private var importError: String?
    @State private var pendingRemoval: TrustedPeer?

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
                    controller.join(peer: peer)
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
                Tap a device to join the connection it is hosting. Swipe a row to \
                stop trusting it. An expired card can no longer pair — ask that \
                device for a fresh one, or trade cards again.
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
            Text("Join")
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
                    .onChange(of: importDraft) { _, _ in importError = nil }
                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if let info = previewInfo {
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
                Button("Paste") {
                    if let pasted = UIPasteboard.general.string {
                        importDraft = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .disabled(!UIPasteboard.general.hasStrings)
                Button("Trust this device") {
                    if let error = controller.importPeerCard(importDraft) {
                        importError = error
                    } else {
                        importDraft = ""
                        showImport = false
                    }
                }
                .disabled(previewInfo == nil)
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

    /// The pasted card decoded for preview, or nil while it is empty or invalid.
    private var previewInfo: IdentityCardInfo? {
        let trimmed = importDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return IdentityCardInfo.parse(card: trimmed)
    }
}
