import SwiftUI
import AppIntents
import WoodsWhisperKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var launcher = RecordingLauncher.shared

    var body: some View {
        TabView {
            DocumentsView()
                .tabItem { Label("Documents", systemImage: "doc.text") }

            LogView()
                .tabItem { Label("Log", systemImage: "terminal") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .overlay(alignment: .bottom) {
            if let message = model.busyMessage {
                BusyBanner(message: message)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.busyMessage)
        .alert("Something went wrong",
               isPresented: Binding(get: { model.setupError != nil },
                                    set: { if !$0 { model.setupError = nil } })) {
            Button("OK", role: .cancel) { model.setupError = nil }
        } message: {
            Text(model.setupError ?? "")
        }
        // "New Recording" requested from outside the app (Control / Lock Screen / Action Button /
        // Siri / Shortcuts). Present the recorder straight to the Inbox, wherever we are.
        .sheet(isPresented: $launcher.pending) {
            RecordingSheet(title: "New Recording",
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                let inbox = model.documents.inboxDocument()
                model.addDeviceRecording(audioURL: url, duration: duration, toDocument: inbox.id)
            }
        }
        .onOpenURL { url in
            if url == woodsWhisperRecordURL { launcher.request() }
        }
    }
}

// MARK: - "New Recording" App Shortcut

/// Exposes the (shared) `StartRecordingIntent` to Siri/Spotlight. `AppShortcutsProvider` must live
/// in the app target; the intent itself is defined in WoodsWhisperKit so the Control extension can
/// share it.
struct WoodsWhisperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "New recording in \(.applicationName)",
                "Start a recording in \(.applicationName)"
            ],
            shortTitle: "New Recording",
            systemImageName: "mic.fill"
        )
    }
}

struct BusyBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message).font(.callout)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 4)
    }
}
