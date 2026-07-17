import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The configure-mode home flow, mirroring the desktop wizard + hub: set up
/// the standing secret (generate a new one or import the existing one), name
/// this device, then the hub — identity, discovered device list, start/join.
struct ConfigureView: View {
    enum Step: Equatable {
        case choice
        case importSecret
        case name
        case hub
        /// The device picker, shown only after choosing Join on the hub.
        case join
        /// Quick pair (PIN), reachable before setup and from the hub.
        case quick
    }

    @Environment(SessionController.self) private var controller
    /// nil until first render; transitions are user-driven from then on.
    @State private var step: Step?

    var body: some View {
        Group {
            switch step ?? derivedStep {
            case .choice:
                SecretChoiceView(step: stepBinding)
            case .importSecret:
                SecretImportView(step: stepBinding)
            case .name:
                NameDeviceView(step: stepBinding)
            case .hub:
                HubView(step: stepBinding)
            case .join:
                JoinView(step: stepBinding)
            case .quick:
                QuickPairView(step: stepBinding)
            }
        }
        .navigationTitle("duocb")
        .onAppear {
            if step == nil {
                step = derivedStep
            }
        }
    }

    /// This build's marketing version (`CFBundleShortVersionString`), shown on
    /// the home screen.
    static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// Where the stored identity puts us: no secret → wizard start; secret but
    /// no confirmed name → naming; both → the hub.
    private var derivedStep: Step {
        if controller.secret == nil { return .choice }
        if controller.deviceName == nil { return .name }
        return .hub
    }

    private var stepBinding: Binding<Step> {
        Binding(get: { step ?? derivedStep }, set: { step = $0 })
    }
}

/// Wizard entry: create a fresh secret or paste the one from another device.
private struct SecretChoiceView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: ConfigureView.Step

    var body: some View {
        Form {
            SessionFailureSection()
            Section {
                Button {
                    // Persist immediately and go straight to naming: the secret
                    // is always copyable later from the hub, so a separate
                    // "save the secret" confirmation step guards nothing. Only
                    // advance once it is actually in the Keychain.
                    if controller.setSecret(SessionController.generateToken()) {
                        step = .name
                    }
                } label: {
                    Label("Create a new secret", systemImage: "key")
                }
                Button {
                    step = .importSecret
                } label: {
                    Label("Use an existing secret", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Set up the shared secret")
            } footer: {
                Text("""
                    All of your devices share one secret. Create it on the first \
                    device, then import the same secret on every other one.
                    """)
            }
            Section {
                Button {
                    step = .quick
                } label: {
                    Label("Quick pair with a PIN", systemImage: "bolt")
                }
            } footer: {
                Text("""
                    Pair two devices right now with a short PIN — no shared \
                    secret or setup needed.
                    """)
            }
            AppVersionSection()
        }
    }
}

/// The app version, in the normal scroll flow at the bottom of home screens.
struct AppVersionSection: View {
    var body: some View {
        Section {
        } footer: {
            Text("duocb v\(ConfigureView.appVersion)")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// Import the secret copied from another device: masked paste with live
/// validation and the fingerprint to confirm against the other device.
private struct SecretImportView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: ConfigureView.Step
    @State private var draft = ""

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tokenError: String? {
        trimmed.isEmpty ? nil : SessionController.validateToken(trimmed)
    }

    var body: some View {
        Form {
            Section {
                SecureField("Secret copied from your other device", text: $draft)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let tokenError {
                    Text(tokenError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if let fingerprint = SessionController.tokenFingerprint(trimmed) {
                    LabeledContent("Fingerprint") {
                        Text(fingerprint)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
                Button("Paste") {
                    if let pasted = UIPasteboard.general.string {
                        draft = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .disabled(!UIPasteboard.general.hasStrings)
            } header: {
                Text("Import the shared secret")
            } footer: {
                Text("""
                    Paste the secret itself (from “Copy secret”) — not the \
                    fingerprint. Confirm the fingerprint shown here matches the \
                    other device before continuing.
                    """)
            }

            Section {
                Button("Use this secret") {
                    // Advance only once the secret is actually in the Keychain.
                    if controller.setSecret(trimmed) {
                        step = .name
                    }
                }
                .disabled(trimmed.isEmpty || tokenError != nil)
                Button("Cancel", role: .cancel) {
                    step = .choice
                }
            }
        }
    }
}

/// Name this device: a short name plus the permanent suffix, previewed as the
/// identity the other devices will see.
private struct NameDeviceView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: ConfigureView.Step
    @State private var draft = ""
    @State private var loaded = false

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespaces)
    }

    private var nameError: String? {
        SessionController.validateName(trimmed)
    }

    var body: some View {
        Form {
            Section {
                TextField("e.g. phone", text: $draft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let nameError, !trimmed.isEmpty {
                    Text(nameError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if nameError == nil {
                    LabeledContent("Broadcast as") {
                        Text("\(trimmed)_\(controller.suffix)")
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            } header: {
                Text("Name this device")
            } footer: {
                Text("""
                    A short name plus this device's permanent id — other devices \
                    will see it in their list. Letters, digits, and '-' only \
                    (max 24 characters).
                    """)
            }

            Section {
                Button("Save name") {
                    controller.saveName(trimmed)
                    step = .hub
                }
                .disabled(nameError != nil)
                if controller.hasIdentity {
                    Button("Cancel", role: .cancel) {
                        step = .hub
                    }
                }
            }
        }
        .onAppear {
            if !loaded {
                draft = controller.deviceName ?? Self.defaultDeviceName()
                loaded = true
            }
        }
    }

    /// A reasonable default name from the device name: lowercased,
    /// non-alphanumerics collapsed to single dashes (e.g. "Bob's iPhone" →
    /// "bob-s-iphone").
    private static func defaultDeviceName() -> String {
        let collapsed = UIDevice.current.name.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }
            .joined()
        let name = collapsed
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(name.prefix(24))
    }
}

/// The failed-session banner (message + Reconnect/Dismiss), shared by every
/// screen a dead session can land on: the hub, quick pair, and the setup
/// choice screen (where identity-less quick failures surface).
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

/// Copy the secret to the pasteboard: local-only (not Handoff'd) and expiring,
/// like the old setup form's Copy.
@MainActor
func copySecret(_ token: String) {
    UIPasteboard.general.setItems(
        [[UTType.utf8PlainText.identifier: token]],
        options: [
            .localOnly: true,
            .expirationDate: Date.now.addingTimeInterval(5 * 60),
        ]
    )
}

/// A "Copy secret" button that acknowledges the tap: it reads "✔ Copied" for a
/// couple of seconds after copying. Also reused for the quick-pair PIN via a
/// custom title (same local-only, expiring pasteboard behavior).
struct CopySecretButton: View {
    let secret: String
    var title = "Copy secret"
    @State private var copied = false

    var body: some View {
        Button(copied ? "✔ Copied" : title) {
            copySecret(secret)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .buttonStyle(.borderless)
    }
}
