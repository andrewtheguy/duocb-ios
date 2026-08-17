import SwiftUI

/// Settings: the signaling channel, and the destructive identity actions.
///
/// The channel is the desktop's `--lan-only` / `--nostr-only`, which that build
/// fixes at launch so both flows always agree. iOS has no command line, so it
/// is a setting read when a session starts — a running session never changes
/// channel underneath itself, which is the same guarantee in practice.
struct SettingsView: View {
    @Environment(SessionController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase
    @Binding var step: SetupView.Step

    @State private var confirmReset = false
    @State private var revealPrivateKey = false

    var body: some View {
        Form {
            channelSection
            privateKeySection
            resetSection
            Section {
                Button("Back", role: .cancel) { step = .hub }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Hide the key before the system takes its snapshot. iOS captures the
        // window as the app leaves the foreground and shows that image in the
        // app switcher and on the next launch — a revealed private key would be
        // in it, and the snapshot outlives the app's own memory. `.inactive`
        // is the phase the capture happens in, so anything short of active
        // re-hides it.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                revealPrivateKey = false
            }
        }
        .confirmationDialog(
            "Start over with a new identity?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset identity", role: .destructive) {
                controller.resetIdentity()
                step = .choice
            }
        } message: {
            Text("""
                This device gets a brand-new key, loses its name and card, and \
                forgets every trusted device — those entries name the old key. \
                Your other devices keep trusting the old key until you remove it \
                there, and pairing again means trading cards from scratch. This \
                device's permanent id is kept.
                """)
        }
    }

    private var channelSection: some View {
        Section {
            Picker(selection: Binding(
                get: { controller.channel },
                set: { controller.setChannel($0) }
            )) {
                ForEach(SignalChannel.allCases, id: \.self) { channel in
                    Text(channel.title).tag(channel)
                }
            } label: {
                Label("Channel", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .pickerStyle(.inline)
        } header: {
            Text("How devices find each other")
        } footer: {
            Text(controller.channel.note + """


                This applies to trading cards and to clipboard sessions alike, \
                and takes effect on the next connection. Both devices must be \
                set to a channel they share.
                """)
        }
    }

    private var privateKeySection: some View {
        Section {
            if let nsec = controller.identitySecret {
                if revealPrivateKey {
                    Text(nsec)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    CopyButton(value: nsec, title: "Copy private key", sensitive: true)
                    Button("Hide") { revealPrivateKey = false }
                        .buttonStyle(.borderless)
                } else {
                    Button("Show private key") { revealPrivateKey = true }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Private key")
        } footer: {
            Text("""
                Save this somewhere safe to restore *this* device's identity onto \
                a replacement phone — the trusted-device list is not part of it \
                and has to be rebuilt by trading cards. Anyone holding this key \
                can impersonate this device to everyone that trusts it. The copy \
                is local to this device and expires from the clipboard after five \
                minutes.
                """)
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset identity…", role: .destructive) { confirmReset = true }
                .buttonStyle(.borderless)
        }
    }
}
