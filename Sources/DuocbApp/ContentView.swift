import SwiftUI

/// Root router, mirroring the desktop's `Screen` enum.
///
/// The order of these branches is the contract. A received card outranks
/// everything: `peer_card_received` is guaranteed to arrive before the
/// session's closing `idle`, so the confirmation screen must be up before
/// teardown is processed, or the card would be dropped on the floor with no way
/// to get it back short of re-trading.
///
/// Below that, card setup and a clipboard session are different screens even
/// though both are "a session is running" — card setup shows a PIN and never
/// carries clipboard content.
struct ContentView: View {
    @Environment(SessionController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            if controller.incomingCard != nil {
                CardConfirmView()
            } else if controller.isCardSetupActive {
                CardPairingView()
            } else if controller.isClipboardSessionActive {
                SessionView()
            } else {
                SetupView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.noteForegrounded()
            }
        }
        #if DEBUG
        .onAppear { controller.autostartFromEnvironment() }
        #endif
    }
}
