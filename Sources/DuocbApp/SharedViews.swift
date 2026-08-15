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

extension SessionController.Phase {
    /// Phase → user copy, mirroring the desktop's status_text(). Lives here
    /// rather than beside one of its callers: both the card-pairing screen and
    /// the clipboard session show the same status line.
    var statusText: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Waiting for the other device…"
        case .resolving: "Looking for the other device…"
        case .connecting: "Connecting…"
        case .authenticating: "Authenticating…"
        case .connected: "Connected"
        case .reconnecting(let attempt, let max): "Reconnecting… (attempt \(attempt) of \(max))"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

/// The unreadable-config banner: a settings file exists that could not be read,
/// so nothing will be saved until the user decides to discard it. Shown on the
/// screens setup can begin from, because that is where a first save is about to
/// be attempted and silently refused.
struct ConfigFailureSection: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        if let reason = controller.configError {
            Section {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                Button("Discard the stored settings and start over", role: .destructive) {
                    controller.discardUnreadableConfig()
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Settings could not be read")
            } footer: {
                Text("""
                    Nothing is saved while this is unresolved, so this device's \
                    name and trusted devices cannot change. Discarding writes a \
                    fresh file and loses whatever the old one held — including \
                    every trusted device, which then have to be traded again.
                    """)
            }
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

/// A fingerprint, rendered for eye-comparison across two screens.
///
/// The layout is fixed rather than fitted, and that is the whole point: the
/// comparison this supports is "do these two screens show the same thing", and
/// a phone and a laptop — or two phones at different Dynamic Type settings —
/// would wrap free-flowing text at different groups, so the same fingerprint
/// would read as two different shapes. Instead the groups are laid out
/// `groupsPerLine` at a time, identically everywhere, and a narrow screen
/// shrinks the glyphs instead of re-wrapping them.
struct FingerprintText: View {
    let fingerprint: String
    /// Five 4-hex-digit groups is the core's whole fingerprint (10 bytes, see
    /// `key_fingerprint`), so this normally puts it on one line.
    var groupsPerLine = 5

    private var lines: [String] {
        let groups = fingerprint.split(separator: " ")
        let perLine = max(1, groupsPerLine)
        return stride(from: 0, to: groups.count, by: perLine).map { start in
            groups[start..<min(start + perLine, groups.count)].joined(separator: " ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { line in
                Text(line.element)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    // Shrink rather than wrap: a re-wrap changes the shape, a
                    // smaller glyph does not.
                    .minimumScaleFactor(0.5)
            }
        }
        .textSelection(.enabled)
    }
}
