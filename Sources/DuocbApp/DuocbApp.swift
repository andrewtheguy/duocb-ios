import SwiftUI

@main
struct DuocbApp: App {
    @State private var controller = SessionController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
        }
    }
}
