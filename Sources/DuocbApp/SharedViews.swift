import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The app version, in the normal scroll flow at the bottom of home screens.
struct AppVersionSection: View {
    /// This build's marketing version (`CFBundleShortVersionString`).
    static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        Section {
        } footer: {
            Text("duocb v\(Self.appVersion)")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// The failed-session banner (message + Reconnect/Dismiss), shared by every
/// screen a dead session can land on.
struct SessionFailureSection: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
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
}

/// A one-line badge naming a non-default signaling channel, matching the
/// desktop hub's. Nothing is shown on the default channel — the card-setup
/// screen's note is where that one is spelled out.
struct ChannelBadge: View {
    let channel: SignalChannel

    var body: some View {
        if let badge = channel.badge {
            Label(badge, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Copy a sensitive value to the pasteboard: local-only (not Handoff'd to
/// other devices) and expiring, so a private key or a PIN does not linger.
@MainActor
func copySensitive(_ value: String) {
    UIPasteboard.general.setItems(
        [[UTType.utf8PlainText.identifier: value]],
        options: [
            .localOnly: true,
            .expirationDate: Date.now.addingTimeInterval(5 * 60),
        ]
    )
}

/// A copy button that acknowledges the tap — "✔ Copied" for a couple of
/// seconds. `sensitive` routes through the local-only, expiring pasteboard
/// (private keys, PINs); ordinary content (a card, a received clipboard item)
/// uses the normal pasteboard, because the whole point of those is to be
/// pasted somewhere else.
struct CopyButton: View {
    let value: String
    var title = "Copy"
    var sensitive = false
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(copied ? "✔ Copied" : title) {
            if sensitive {
                copySensitive(value)
            } else {
                UIPasteboard.general.string = value
            }
            copied = true
            // Cancel the previous reset so the latest tap owns the timer —
            // otherwise an earlier tap's timer clears the acknowledgement
            // before this tap's two seconds are up.
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
        .buttonStyle(.borderless)
    }
}

/// A fingerprint, rendered for eye-comparison across two screens: monospaced,
/// selectable, and wide enough that the grouping never re-wraps differently on
/// the two devices.
struct FingerprintText: View {
    let fingerprint: String

    var body: some View {
        Text(fingerprint)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
