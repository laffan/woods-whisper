import SwiftUI
import Combine
import AppIntents
import WoodsWhisperKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var launcher = RecordingLauncher.shared

    /// Tab selection, so the widget's deep links can land on the Documents tab.
    enum Tab: Hashable { case inbox, documents, log, settings }
    @State private var selectedTab: Tab = .inbox

    var body: some View {
        TabView(selection: $selectedTab) {
            InboxTab()
                .tabItem { Label("Inbox", systemImage: "tray.and.arrow.down") }
                .tag(Tab.inbox)

            DocumentsView()
                .tabItem { Label("Documents", systemImage: "doc.text") }
                .tag(Tab.documents)

            LogView()
                .tabItem { Label("Log", systemImage: "terminal") }
                .tag(Tab.log)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
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
            if url == woodsWhisperRecordURL {
                launcher.request()
            } else if url == woodsWhisperDocumentsURL {
                // Widget background / empty space: just show the list.
                selectedTab = .documents
            } else if let documentID = woodsWhisperDocumentID(from: url) {
                // A tapped widget row (medium/large, which link by URL). The tab switch rides on
                // the launcher below, shared with the small family's App Intent route.
                DocumentLauncher.shared.open(documentID)
            } else if url.isFileURL {
                if url.pathExtension.lowercased() == DocumentArchive.fileExtension {
                    // A Woods Whisper document file (audio + transcriptions) shared from another
                    // device — unpack it into a new document.
                    model.importDocumentArchive(from: url)
                } else {
                    // Audio shared into the app (share sheet / "Open in…") — import as a normal recording.
                    model.importSharedAudio(from: url)
                }
            }
        }
        // Every "open this document" request — the widget's URL links and its App Intent alike —
        // arrives as a launcher value, so the tab switch lives here rather than in `onOpenURL`.
        // `onReceive` (not `onChange`) because DocumentsView clears the value as it consumes it:
        // this delivers the published id itself, so the switch can't lose a race to that reset.
        .onReceive(DocumentLauncher.shared.$pendingDocumentID) { pending in
            if pending != nil { selectedTab = .documents }
        }
        // Cold launch: the App Intent can set the launcher before this view subscribes above (the
        // publisher doesn't replay), so catch an id that's already waiting.
        .onAppear {
            if DocumentLauncher.shared.pendingDocumentID != nil { selectedTab = .documents }
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

// MARK: - Inbox tab

/// Hosts the Inbox as a top-level section. The Inbox document is created on demand and the flat
/// recordings list (`InboxView`) is wrapped in its own navigation stack so it reads like a peer of
/// Documents rather than a row buried inside it.
struct InboxTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var inboxID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let inboxID {
                    InboxView(documentID: inboxID)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(WW.paper)
                }
            }
        }
        .task { inboxID = model.documents.inboxDocument().id }
    }
}

struct BusyBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(WW.moss)
            Text(message)
                .font(.callout)
                .foregroundStyle(WW.ink)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(WW.surface, in: Capsule())
        .overlay(Capsule().stroke(WW.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 4)
    }
}
