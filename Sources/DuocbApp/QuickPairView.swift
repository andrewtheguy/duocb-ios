import SwiftUI

/// Quick pair (the desktop "P" preset): ephemeral pairing with any duocb
/// device via a short rotating PIN — no shared secret, name, or identity
/// involved, so it also works before setup. Hosting moves to SessionView,
/// which shows the PIN; joining dials the PIN typed here.
struct QuickPairView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: ConfigureView.Step
    @State private var draft = ""

    private var canonicalPIN: String? {
        SessionController.normalizePIN(draft)
    }

    var body: some View {
        Form {
            failureSection
            hostSection
            joinSection
            Section {
                Button("Back", role: .cancel) {
                    step = controller.hasIdentity ? .hub : .choice
                }
            }
        }
    }

    /// A failed quick session, with Reconnect — this screen is the landing
    /// spot for quick-session failures when no identity (hub) exists.
    @ViewBuilder
    private var failureSection: some View {
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
    }

    private var hostSection: some View {
        Section {
            Button {
                controller.startQuickHost()
            } label: {
                Label("Show a PIN on this device", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            Text("Show a PIN")
        } footer: {
            Text("""
                A short PIN appears on this device. Enter it on the other \
                device within a minute — it renews every 60 seconds until a \
                device pairs.
                """)
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
                Text("Check the PIN — the last character doesn't match")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("Join") {
                if let pin = canonicalPIN {
                    controller.joinQuick(pin: pin)
                }
            }
            .disabled(canonicalPIN == nil)
        } header: {
            Text("Enter a PIN")
        } footer: {
            Text("Type the PIN shown on the hosting device.")
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
