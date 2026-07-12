import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Config-mode setup: the shared auth token, this device's name, and whether
/// this device starts the pairing (listens) or joins it (dials). Both devices
/// use the same token and different names.
struct SetupView: View {
    @Environment(SessionController.self) private var controller

    @State private var token: String = TokenStore.load() ?? ""
    @AppStorage("myName") private var myName = SetupView.defaultDeviceName()
    @AppStorage("role") private var roleRaw = SessionController.Role.start.rawValue

    private var role: SessionController.Role {
        SessionController.Role(rawValue: roleRaw) ?? .start
    }

    private var tokenError: String? {
        token.isEmpty ? nil : SessionController.validateToken(token)
    }

    private var canStart: Bool {
        !token.isEmpty && tokenError == nil && !myName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            let _ = applyDebugOverrides()
            if case .failed(let message) = controller.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    if controller.lastSettings != nil {
                        Button("Reconnect") { controller.reconnect() }
                    }
                }
            }

            Section {
                Picker("Role", selection: $roleRaw) {
                    Text("Start this pairing").tag(SessionController.Role.start.rawValue)
                    Text("Join").tag(SessionController.Role.join.rawValue)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(role == .start
                    ? "This device listens and publishes its address; run this on one device only."
                    : "This device looks the other one up and dials it.")
            }

            // Mirrors the desktop forms: the starting device never renders the
            // token — masked display + explicit Copy to hand it to the joiner —
            // and the joining device enters it through a masked field.
            if role == .start {
                Section {
                    if !token.isEmpty && tokenError == nil {
                        LabeledContent("Token") {
                            HStack {
                                Text(String(repeating: "•", count: 12))
                                    .font(.system(.footnote, design: .monospaced))
                                Button("Copy") {
                                    UIPasteboard.general.setItems(
                                        [[UTType.utf8PlainText.identifier: token]],
                                        options: [
                                            .localOnly: true,
                                            .expirationDate: Date.now.addingTimeInterval(5 * 60),
                                        ]
                                    )
                                }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if let fingerprint = SessionController.tokenFingerprint(token) {
                            LabeledContent("Fingerprint") {
                                Text(fingerprint).font(.system(.footnote, design: .monospaced))
                            }
                        }
                    } else if !token.isEmpty {
                        Text("The saved token is invalid; generate a new one")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button(token.isEmpty || tokenError != nil ? "Generate token" : "Generate new token") {
                        token = SessionController.generateToken()
                    }
                } header: {
                    Text("Shared token")
                } footer: {
                    Text("Use Copy to transfer the token to the joining device. Token and name are saved automatically when you start.")
                }
            } else {
                Section {
                    SecureField("Token copied from the starting device", text: $token)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let tokenError {
                        Text(tokenError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if let fingerprint = SessionController.tokenFingerprint(token) {
                        LabeledContent("Fingerprint") {
                            Text(fingerprint).font(.system(.footnote, design: .monospaced))
                        }
                    }
                    Button("Paste") {
                        if let pasted = UIPasteboard.general.string {
                            token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!UIPasteboard.general.hasStrings)
                } header: {
                    Text("Shared token")
                } footer: {
                    Text("Paste the token itself (from “Copy”) — not the fingerprint shown on the other device. Token and name are saved after a successful connection.")
                }
            }

            Section {
                TextField("e.g. phone", text: $myName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("My name")
            } footer: {
                Text("The two devices must use the same token and different names. Compare the fingerprint on both devices to confirm the tokens match — the token itself is never displayed again.")
            }

            Section {
                Button(role == .start ? "Start" : "Join") {
                    controller.start(
                        role: role,
                        token: token,
                        name: myName.trimmingCharacters(in: .whitespaces))
                }
                .disabled(!canStart)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("duocb")
    }

    /// E2E-test hook (Debug only): force the role from a launch environment
    /// variable so screenshot-driven tests can render either tab without UI
    /// automation (SIMCTL_CHILD_DUOCB_UI_ROLE=start|join).
    private func applyDebugOverrides() {
        #if DEBUG
        if let role = ProcessInfo.processInfo.environment["DUOCB_UI_ROLE"], roleRaw != role {
            DispatchQueue.main.async { roleRaw = role }
        }
        #endif
    }

    /// A reasonable default my_name from the device name: lowercased,
    /// non-alphanumerics collapsed to single dashes (e.g. "Bob's iPhone" →
    /// "bob-s-iphone"). Naturally distinct from a desktop's name, which
    /// mitigates same-name discovery collisions.
    private static func defaultDeviceName() -> String {
        let collapsed = UIDevice.current.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
        return collapsed
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
