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
            statusSection
            if let error = controller.lastError, controller.phase != .connected {
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

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Circle()
                    .fill(controller.phase == .connected ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text(statusText)
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
                if let text = UIPasteboard.general.string, !text.isEmpty {
                    controller.send(text: text)
                }
            } label: {
                Label("Send clipboard", systemImage: "doc.on.clipboard")
            }
            .disabled(!controller.canSend || !UIPasteboard.general.hasStrings)

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
                        Button("Copy") {
                            UIPasteboard.general.string = item.text
                        }
                        .buttonStyle(.borderless)
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
        case .reconnecting(let backoffSecs): "Reconnecting in \(backoffSecs)s…"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private func shortNodeID(_ id: String) -> String {
        id.count > 16 ? "\(id.prefix(8))…\(id.suffix(8))" : id
    }
}
