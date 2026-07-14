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
    @State private var channel: SessionController.QuickChannel = .nostrLan

    private var canonicalPIN: String? {
        SessionController.normalizePIN(draft)
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
            Button("Join") {
                if let pin = canonicalPIN {
                    controller.joinQuick(pin: pin)
                }
            }
            .disabled(canonicalPIN == nil)
        } header: {
            Text("Enter a PIN")
        } footer: {
            Text("Type the PIN shown on the hosting device — its channel is taken from the PIN automatically.")
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
