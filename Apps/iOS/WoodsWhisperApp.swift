import SwiftUI
import WoodsWhisperKit

@main
struct WoodsWhisperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await model.loadDownloadedModelsAtStartup() }
        }
    }
}
