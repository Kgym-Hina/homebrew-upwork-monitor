import SwiftUI

@main
struct UpworkMonitorApp: App {
    @StateObject private var model = AppModel()

    init() {
        NotificationManager.shared.installDelegate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra("Upwork Monitor", systemImage: "briefcase.fill") {
            MenuBarView()
                .environmentObject(model)
        }
        #endif
    }
}
