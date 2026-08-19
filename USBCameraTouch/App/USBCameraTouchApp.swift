import SwiftUI

@main
struct USBCameraTouchApp: App {
    init() {
        RuntimeBridge.resetForNewLaunch()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
