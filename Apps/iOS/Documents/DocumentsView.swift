import SwiftUI
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

struct DocumentsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var renameTarget: Document?
    @State private var renameText = ""
    @State private var showingRecorder = false
    @State private var shareItem: ShareItem?
    @State private var editingDoc: Document?
    @State private var editingText = ""

    private var allDocuments: [Document] { model.documents.documents }
    private var inbox: Document? { allDocuments.first { $0.title == DocumentStore.inboxTitle } }
    private var userDocuments: [Document] { allDocuments.filter { $0.title != DocumentStore.inboxTitle } }

    var body: some View {
        NavigationStack {
            List {
                // Inbox is pinned at the top: a flat list of recordings (Watch clips and
                // "New Recording" land here), not a document.
                if let inbox {
                    Section {
                        NavigationLink(value: Route.inbox(inbox.id)) {
                            Label { InboxRow(document: inbox) } icon: {
                                Image(systemName: "tray.and.arrow.down")
                            }
                        }
                    }
                }

                Section {
                    ForEach(userDocuments) { doc in
                        NavigationLink(value: Route.document(doc.id)) { DocumentRow(document: doc) }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { model.documents.moveToTrash(doc) }
                                Button("Rename") { startRename(doc) }.tint(.blue)
                            }
                            .swipeActions(edge: .leading) {
                                Button("Copy") { copy(doc) }.tint(.gray)
                                Button("Share") { shareItem = ShareItem(text: doc.combinedText) }.tint(.indigo)
                                Button("Edit") { startEdit(doc) }.tint(.blue)
                            }
                    }
                } header: {
                    if inbox != nil && !userDocuments.isEmpty { Text("Documents") }
                }

                if !model.documents.trash.isEmpty {
                    Section {
                        NavigationLink(value: Route.trash) {
                            Label {
                                TrashRow(count: model.documents.trash.count)
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Documents")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .document(let id): DocumentDetailView(documentID: id)
                case .inbox(let id):    InboxView(documentID: id)
                case .trash:            TrashView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let doc = model.documents.createDocument()
                        startRename(doc)
                    } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New Document")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingRecorder = true } label: { Image(systemName: "mic.badge.plus") }
                        .accessibilityLabel("New Recording")
                }
            }
            .overlay {
                if allDocuments.isEmpty {
                    ContentUnavailableView("No documents yet",
                                           systemImage: "doc.text",
                                           description: Text("Tap ✎ to start a document, or the mic to record straight to your Inbox. Watch recordings land in “Inbox.”"))
                }
            }
            .alert("Rename document", isPresented: Binding(get: { renameTarget != nil },
                                                           set: { if !$0 { renameTarget = nil } })) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    if let t = renameTarget { model.documents.rename(t, to: renameText) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .sheet(isPresented: $showingRecorder) {
                RecordingSheet(title: "New Recording",
                               makeURL: { model.documents.newAudioURL().url }) { url, duration in
                    let inbox = model.documents.inboxDocument()
                    model.addDeviceRecording(audioURL: url, duration: duration, toDocument: inbox.id)
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(activityItems: [item.text])
            }
            .sheet(item: $editingDoc) { doc in
                TextEditorSheet(title: doc.title, text: $editingText) {
                    model.documents.setParagraphs(Document.paragraphs(from: editingText), in: doc.id)
                }
            }
        }
    }

    private func startRename(_ document: Document) {
        renameText = document.title
        renameTarget = document
    }

    private func startEdit(_ document: Document) {
        editingText = document.combinedText
        editingDoc = document
    }

    private func copy(_ document: Document) {
        #if canImport(UIKit)
        UIPasteboard.general.string = document.combinedText
        #endif
        wwLog("Copied “\(document.title)” to clipboard", .general)
    }

    /// Navigation routes by document id so views always read live store state, not a stale copy.
    enum Route: Hashable {
        case document(UUID)
        case inbox(UUID)
        case trash
    }
}

private struct DocumentRow: View {
    let document: Document
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    private var subtitle: String {
        let paras = document.paragraphs.count
        let body = "\(paras) paragraph\(paras == 1 ? "" : "s")"
        let count = document.recordings.count
        let clips = count == 0 ? "" : " · \(count) recording\(count == 1 ? "" : "s")"
        return body + clips
    }
}

private struct InboxRow: View {
    let document: Document
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DocumentStore.inboxTitle)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    private var subtitle: String {
        let count = document.recordings.count
        return count == 0 ? "No recordings" : "\(count) recording\(count == 1 ? "" : "s")"
    }
}

private struct TrashRow: View {
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Trash")
            Text("\(count) document\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
