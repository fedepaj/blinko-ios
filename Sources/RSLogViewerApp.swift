import SwiftUI

@main
struct RSLogViewerApp: App {
    @StateObject private var model = SessionModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
