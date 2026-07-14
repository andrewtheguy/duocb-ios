import SwiftUI
import UIKit

/// The live session: status, identity fingerprint, sending, and the inbox.
/// Received text is never auto-revealed or auto-copied — each item shows only
/// size + CRC + time until the user peeks, and reaches the clipboard only via
/// an explicit Copy (matching the desktop model).
struct SessionView: View {
    @Environment(SessionController.self) private var controller

    @State private var composeText = ""
    @State private var showConnPath = false

    var body: some View {
        List {
            pinSection
            statusSection
            if let error = controller.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            sendSection
            if let outbox = controller.outbox {
                Section("Last sent") {
                    itemSummary(outbox)
                }
            }
            inboxSection
        }
        .navigationTitle("duocb")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Stop", role: .destructive) { controller.stop() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.connPaths = []
                    controller.queryConnPath()
                    showConnPath = true
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .disabled(controller.phase != .connected)
            }
        }
        .sheet(isPresented: $showConnPath, onDismiss: { controller.connPaths = nil }) {
            ConnPathSheet()
        }
    }

    // MARK: - Sections

    /// Quick host: the rotating PIN, front and center until a peer pairs
    /// (the runtime then sends pin_cleared and this section disappears).
    @ViewBuilder
    private var pinSection: some View {
        if let pin = controller.pinDisplay {
            Section {
                VStack(spacing: 8) {
                    Text(pin)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    if let deadline = controller.pinDeadline {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let secs = max(0, Int(deadline.timeIntervalSince(context.date).rounded()))
                            Text("renews in \(secs)s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                CopySecretButton(secret: pin, title: "Copy PIN")
                Button {
                    controller.refreshPIN()
                } label: {
                    Label("New PIN", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("PIN")
            } footer: {
                Text("Enter this PIN on the other device to pair. New PIN replaces it right away and stops every earlier one from working.")
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Circle()
                    .fill(controller.phase == .connected ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text(statusText)
            }
            // Quick sessions are identity-less; the broadcast identity only
            // applies to configure-mode sessions.
            if !controller.isQuickSession, let identity = controller.displayIdentity {
                LabeledContent("This device") {
                    Text(identity).font(.system(.footnote, design: .monospaced))
                }
            }
            if let joined = controller.joinedPeer {
                LabeledContent("Joining") {
                    Text(joined).font(.system(.footnote, design: .monospaced))
                }
            }
            if let fingerprint = controller.tokenFingerprint {
                LabeledContent("Fingerprint") {
                    Text(fingerprint).font(.system(.footnote, design: .monospaced))
                }
            }
            if let peer = controller.peerNodeID {
                LabeledContent("Peer") {
                    Text(shortNodeID(peer)).font(.system(.footnote, design: .monospaced))
                }
            }
        }
    }

    private var sendSection: some View {
        Section("Send") {
            Button {
                // Read the pasteboard at tap time — gating the button on
                // UIPasteboard state is unreliable (SwiftUI won't re-render
                // when the pasteboard changes, leaving it stale-disabled).
                if let text = UIPasteboard.general.string, !text.isEmpty {
                    controller.send(text: text)
                } else {
                    controller.lastError = "The clipboard is empty"
                }
            } label: {
                Label("Send clipboard", systemImage: "doc.on.clipboard")
            }
            .disabled(!controller.canSend)

            HStack {
                TextField("Or type text to send…", text: $composeText, axis: .vertical)
                    .lineLimit(1...4)
                Button {
                    controller.send(text: composeText)
                    composeText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .disabled(!controller.canSend || composeText.isEmpty)
            }
        }
    }

    private var inboxSection: some View {
        Section("Received") {
            if controller.inbox.isEmpty {
                Text("Nothing received yet")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            ForEach(controller.inbox) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        itemSummary(item)
                        Spacer()
                        Button(item.expanded ? "Hide" : "Peek") {
                            controller.togglePeek(item.id)
                        }
                        .buttonStyle(.borderless)
                        CopyTextButton(text: item.text)
                    }
                    if item.expanded {
                        Text(item.peekText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private func itemSummary(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(item.sizeDisplay) · \(item.crcDisplay)")
                .font(.system(.footnote, design: .monospaced))
            Text(item.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Display helpers

    /// Phase → user copy, mirroring the desktop's status_text().
    private var statusText: String {
        switch controller.phase {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Waiting for the other device…"
        case .resolving: "Looking up the peer…"
        case .connecting: "Connecting…"
        case .authenticating: "Authenticating…"
        case .connected: "Connected"
        case .reconnecting(let attempt, let max): "Reconnecting… (attempt \(attempt) of \(max))"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private func shortNodeID(_ id: String) -> String {
        id.count > 16 ? "\(id.prefix(8))…\(id.suffix(8))" : id
    }
}

/// A "Copy" button that acknowledges the tap: it reads "✔ Copied" for a couple
/// of seconds after copying arbitrary text to the pasteboard (the received
/// clipboard items — unlike the secret, these are ordinary clipboard content).
struct CopyTextButton: View {
    let text: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(copied ? "✔ Copied" : "Copy") {
            UIPasteboard.general.string = text
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
