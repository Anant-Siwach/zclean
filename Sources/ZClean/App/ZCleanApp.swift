import SwiftUI

@main
struct ZCleanApp: App {
    @StateObject private var app = AppState.shared
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("ZClean", id: "main") {
            MainView()
                .environmentObject(app)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 740)

        Settings {
            SettingsView().environmentObject(app)
        }

        MenuBarExtra("ZClean", systemImage: "sparkles", isInserted: $showMenuBar) {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}
