import SwiftUI
import AppIntents

@main
struct WoodsWhisperWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
                .tint(WWWatch.moss)
                .task { WoodsWhisperWatchShortcuts.updateAppShortcutParameters() }
        }
    }
}

// The watch palette lives in this file (rather than its own) so an already-generated
// Xcode project picks it up without an xcodegen regen.

/// Watch-side palette: the same moss / ember / ochre family as the iOS app, tuned for the
/// always-dark watch screen. (The iOS theme's dynamic colors live in the app target; the Watch
/// only ever renders dark, so these are static.)
enum WWWatch {
    /// The one accent: sage moss.
    static let moss = Color(red: 0.576, green: 0.675, blue: 0.549)
    /// Recording / destructive: muted ember.
    static let ember = Color(red: 0.851, green: 0.439, blue: 0.357)
    /// Attention / pending: muted ochre.
    static let amber = Color(red: 0.812, green: 0.655, blue: 0.333)
}

/// Small tracked-uppercase section label, mirroring the iOS list headers.
struct WatchSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
