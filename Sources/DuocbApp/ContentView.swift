import SwiftUI

/// Root router: the configure flow (setup wizard or hub) until a session is
/// running, then the session screen. On return to foreground, nudges the
/// controller to catch up on events and detect a runtime that died while the
/// app was suspended.
struct ContentView: View {
    @Environment(SessionController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            if controller.isSessionActive {
                SessionView()
            } else {
                ConfigureView()
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
