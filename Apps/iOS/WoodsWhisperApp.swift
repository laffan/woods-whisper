import SwiftUI
import AppIntents
import WoodsWhisperKit

@main
struct WoodsWhisperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    WoodsWhisperShortcuts.updateAppShortcutParameters()
                    await model.loadDownloadedModelsAtStartup()
                    // Seed the Watch's record-target picker once the session has had time to activate.
                    model.syncDocumentsToWatch()
                }
        }
    }
}
