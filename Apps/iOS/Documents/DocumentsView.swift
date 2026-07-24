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
    private var userDocuments: [Document] { allDocuments.filter { $0.title != DocumentStore.inboxTitle } }
    private var pinnedDocuments: [Document] { userDocuments.filter { $0.isPinned } }
    private var unpinnedDocuments: [Document] { userDocuments.filter { !$0.isPinned } }

    var body: some View {
        NavigationStack {
            List {
                // Pinned documents are held at the top in their own section.
                if !pinnedDocuments.isEmpty {
                    Section {
                        ForEach(pinnedDocuments) { documentRow($0) }
                    } header: {
                        WWSectionHeader("Pinned")
                    }
                }

                Section {
                    ForEach(unpinnedDocuments) { documentRow($0) }
                } header: {
                    if !pinnedDocuments.isEmpty && !unpinnedDocuments.isEmpty {
                        WWSectionHeader("Documents")
                    }
                }

                if !model.documents.trash.isEmpty {
                    Section {
                        NavigationLink(value: Route.trash) {
                            Label {
                                TrashRow(count: model.documents.trash.count)
                            } icon: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .light))
                                    .foregroundStyle(WW.inkTertiary)
                            }
                        }
                        .wwRow()
                    }
                }
            }
            .wwList()
            .navigationTitle("Documents")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .document(let id): DocumentDetailView(documentID: id)
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
                if userDocuments.isEmpty {
                    WWEmptyState(title: "No documents yet",
                                 systemImage: "doc.text",
                                 message: "Tap ✎ to start a document, or the mic to record straight to your Inbox. Watch recordings land in the Inbox tab.")
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

    /// One document row with its swipe actions, shared by the Pinned and Documents sections.
    @ViewBuilder
    private func documentRow(_ doc: Document) -> some View {
        NavigationLink(value: Route.document(doc.id)) { DocumentRow(document: doc) }
            .wwRow()
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
            .swipeActions(edge: .trailing) {
                Button("Delete", role: .destructive) { model.documents.moveToTrash(doc) }
                    .tint(WW.ember)
                Button("Rename") { startRename(doc) }.tint(WW.slate)
                Button(doc.isPinned ? "Unpin" : "Pin") {
                    model.documents.setPinned(!doc.isPinned, for: doc.id)
                }.tint(WW.amber)
            }
            .swipeActions(edge: .leading) {
                Button("Copy") { copy(doc) }.tint(WW.inkTertiary)
                Button("Share") { shareItem = ShareItem(text: doc.combinedText) }.tint(WW.violet)
                Button("Edit") { startEdit(doc) }.tint(WW.slate)
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
        case trash
    }
}

private struct DocumentRow: View {
    let document: Document
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if document.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WW.moss)
                }
                Text(document.title)
                    .font(WW.rowTitle)
                    .foregroundStyle(WW.ink)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(WW.inkSecondary)
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

private struct TrashRow: View {
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Trash")
                .font(WW.rowTitle)
                .foregroundStyle(WW.inkSecondary)
            Text("\(count) document\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(WW.inkTertiary)
        }
    }
}
