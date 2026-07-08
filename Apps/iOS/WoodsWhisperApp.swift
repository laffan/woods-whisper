import SwiftUI
import AppIntents
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

@main
struct WoodsWhisperApp: App {
    @StateObject private var model = AppModel()
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

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

#if canImport(UIKit)
/// Minimal app delegate whose only job is to answer the system's supported-orientation query from
/// the "Allow Rotation" setting. SwiftUI has no first-class orientation lock, so the interface
/// orientations are gated here and re-evaluated on demand via `AppDelegate.applyOrientationLock()`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask {
        AppSettings.shared.allowRotation ? .all : .portrait
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// Re-evaluate the supported orientations after the setting changes, snapping the window back to
    /// portrait when rotation was just disabled.
    @MainActor
    static func applyOrientationLock() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationLock)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif
