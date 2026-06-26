import SwiftUI
import AppIntents

@main
struct WoodsWhisperWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
                .task { WoodsWhisperWatchShortcuts.updateAppShortcutParameters() }
        }
    }
}
