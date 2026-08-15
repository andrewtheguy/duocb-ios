import SwiftUI
import UIKit

/// The home flow, mirroring the desktop wizard + hub: set up this
/// installation's application identity (generate a keypair or restore one),
/// name this device, then the hub — identity, trusted devices, host/join.
struct SetupView: View {
    /// Where the flow is, matching the desktop's `ConfigureStep` plus the two
    /// screens iOS reaches from the hub rather than a menu.
    enum Step: Equatable {
        case choice
        case importIdentity
        case name
        case hub
        /// The trusted-device picker, shown only after choosing Join.
        case join
        /// Card setup's entry screen: show a PIN, or type one.
        case cardSetup
        case settings
    }

    @Environment(SessionController.self) private var controller
    /// nil until first render; transitions are user-driven from then on.
    @State private var step: Step?

    var body: some View {
        Group {
            switch step ?? derivedStep {
            case .choice:
                IdentityChoiceView(step: stepBinding)
            case .importIdentity:
                IdentityImportView(step: stepBinding)
            case .name:
                NameDeviceView(step: stepBinding)
            case .hub:
                HubView(step: stepBinding)
            case .join:
                JoinPickerView(step: stepBinding)
            case .cardSetup:
                CardSetupView(step: stepBinding)
            case .settings:
                SettingsView(step: stepBinding)
            }
        }
        .navigationTitle("duocb")
        .onAppear {
            if step == nil {
                step = derivedStep
            }
        }
        // A reset drops the identity out from under whatever screen is showing,
        // so follow the stored state back to the wizard rather than stranding
        // the user on a hub with nothing behind it.
        .onChange(of: controller.hasIdentity) { _, has in
            if !has { step = derivedStep }
        }
    }

    /// Where the stored identity puts us: no key → wizard start; a key but no
    /// confirmed name (and so no self-card) → naming; both → the hub.
    private var derivedStep: Step {
        if controller.identitySecret == nil { return .choice }
        if controller.deviceName == nil || controller.selfCard == nil { return .name }
        return .hub
    }

    private var stepBinding: Binding<Step> {
        Binding(get: { step ?? derivedStep }, set: { step = $0 })
    }
}

/// Wizard entry: mint a fresh application keypair, or restore an existing one.
private struct IdentityChoiceView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: SetupView.Step

    var body: some View {
        Form {
            SessionFailureSection()
            Section {
                Button {
                    // Persist immediately and go straight to naming: the key is
                    // always copyable later from settings, so a separate "save
                    // your key" step guards nothing. Only advance once it is
                    // actually in the Keychain.
                    if controller.setIdentity(SessionController.generateIdentity()) {
                        step = .name
                    }
                } label: {
                    Label("Create this device's identity", systemImage: "key")
                }
                Button {
                    step = .importIdentity
                } label: {
                    Label("Restore a saved private key", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Set up this device")
            } footer: {
                Text("""
                    Every device gets its own identity — there is no shared \
                    secret to copy around. Devices come to trust each other by \
                    trading signed cards, which you do once per pair from the \
                    hub. Restore is for moving *this* device's identity to a \
                    replacement phone; the trusted-device list is not restored \
                    with it and has to be rebuilt by trading cards again.
                    """)
            }
            AppVersionSection()
        }
    }
}

/// Restore a saved private key, with live validation and the resulting
/// fingerprint to confirm against what the peers have on file.
private struct IdentityImportView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: SetupView.Step
    @State private var draft = ""

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var keyError: String? {
        trimmed.isEmpty ? nil : SessionController.validateIdentity(trimmed)
    }

    var body: some View {
        Form {
            Section {
                SecureField("Private key (nsec1…)", text: $draft)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let keyError {
                    Text(keyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if !trimmed.isEmpty,
                          let fingerprint = SessionController.identityFingerprint(trimmed) {
                    LabeledContent("Fingerprint") {
                        FingerprintText(fingerprint: fingerprint)
                    }
                }
                Button("Paste") {
                    if let pasted = UIPasteboard.general.string {
                        draft = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .disabled(!UIPasteboard.general.hasStrings)
            } header: {
                Text("Restore this device's identity")
            } footer: {
                Text("""
                    Paste the private key itself (from “Copy private key”), not \
                    the fingerprint. Your other devices already trust this key, \
                    so the fingerprint shown here should match what they list \
                    for this device.
                    """)
            }

            Section {
                Button("Use this key") {
                    // Advance only once the key is actually in the Keychain.
                    if controller.setIdentity(trimmed) {
                        step = .name
                    }
                }
                .disabled(trimmed.isEmpty || keyError != nil)
                Button("Cancel", role: .cancel) {
                    step = .choice
                }
            } footer: {
                Text("""
                    This replaces any identity already on this device, including \
                    its trusted-device list — those entries name the old key and \
                    would be meaningless under the new one.
                    """)
            }
        }
    }
}

/// Name this device: a short name plus the permanent suffix, previewed as the
/// identity that goes on the signed card.
private struct NameDeviceView: View {
    @Environment(SessionController.self) private var controller
    @Binding var step: SetupView.Step
    @State private var draft = ""
    @State private var loaded = false

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespaces)
    }

    private var nameError: String? {
        trimmed.isEmpty ? "enter a name" : SessionController.validateName(trimmed)
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
                    LabeledContent("Card name") {
                        Text(SessionController.displayIdentity(name: trimmed, suffix: controller.suffix))
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            } header: {
                Text("Name this device")
            } footer: {
                Text("""
                    A short name plus this device's permanent id. Letters, \
                    digits, and '-' only (max 24 characters).
                    """)
            }

            Section {
                Button(controller.selfCard == nil ? "Save name" : "Rename and re-issue card") {
                    controller.saveName(trimmed)
                    step = .hub
                }
                .disabled(nameError != nil)
                if controller.hasIdentity {
                    Button("Cancel", role: .cancel) {
                        step = .hub
                    }
                }
            } footer: {
                Text("""
                    The name is signed into this device's card, so renaming \
                    issues a new one. Devices that already trust you keep \
                    showing the old name until you trade cards with them again.
                    """)
            }
        }
        .onAppear {
            if !loaded {
                draft = controller.deviceName ?? Self.defaultDeviceName()
                loaded = true
            }
        }
    }

    /// A reasonable default from the device name: lowercased, non-alphanumerics
    /// collapsed to single dashes (e.g. "Bob's iPhone" → "bob-s-iphone").
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
