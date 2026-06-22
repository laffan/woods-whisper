import SwiftUI
import WoodsWhisperKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            RecordingsView()
                .tabItem { Label("Recordings", systemImage: "waveform") }

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
