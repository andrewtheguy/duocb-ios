import SwiftUI
import UIKit

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

            Section("Shared token") {
                TextField("dXXXXXXXX… (47 characters)", text: $token)
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
                HStack {
                    Button("Generate") { token = SessionController.generateToken() }
                    Spacer()
                    Button("Paste") {
                        if let pasted = UIPasteboard.general.string {
                            token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .disabled(!UIPasteboard.general.hasStrings)
                }
                .buttonStyle(.borderless)
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
