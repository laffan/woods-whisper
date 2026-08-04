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

    /// Rows push their document by value rather than wrapping it in a `NavigationLink`, so a row can
    /// carry both a tap (open / toggle) and a long press (enter selection) without the two competing.
    @State private var path: [Route] = []

    // Long-press-to-select, mirroring the Inbox's batch mode: Copy / Pin / Share / Delete applied to
    // several documents at once.
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []

    private var allDocuments: [Document] { model.documents.documents }
    private var userDocuments: [Document] { allDocuments.filter { $0.title != DocumentStore.inboxTitle } }
    private var pinnedDocuments: [Document] { userDocuments.filter { $0.isPinned } }
    private var unpinnedDocuments: [Document] { userDocuments.filter { !$0.isPinned } }

    /// The selected documents in the order the list shows them (pinned first), so combined text
    /// reads the same way the screen does.
    private var selectedDocuments: [Document] {
        (pinnedDocuments + unpinnedDocuments).filter { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $path) {
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

                // Trash isn't part of the selectable set, so it steps out of the way while selecting.
                if !model.documents.trash.isEmpty && !selectionMode {
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
            .navigationTitle(selectionMode ? "\(selected.count) selected" : "Documents")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .document(let id): DocumentDetailView(documentID: id)
                case .trash:            TrashView()
                }
            }
            .toolbar {
                if selectionMode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { exitSelection() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(selected.count == userDocuments.count ? "Deselect All" : "Select All") {
                            selectAll()
                        }
                    }
                } else {
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
            }
            // Batch actions. Copy and Share combine the selected documents into one Markdown file;
            // Pin flips the whole selection (to Unpin once they're all pinned); Delete bins them.
            .safeAreaInset(edge: .bottom) {
                if selectionMode {
                    WWBatchBar {
                        WWBatchButton("Delete", "trash", role: .destructive) { deleteSelected() }
                        WWBatchButton("Copy", "doc.on.doc") { copySelected() }
                        WWBatchButton(allSelectedArePinned ? "Unpin" : "Pin",
                                      allSelectedArePinned ? "pin.slash" : "pin") { pinSelected() }
                        WWBatchButton("Share", "square.and.arrow.up") {
                            shareItem = ShareItem(text: MarkdownBackup.combined(selectedDocuments))
                        }
                    }
                    .disabled(selected.isEmpty)
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
    ///
    /// Tap opens the document — or toggles it while selecting — and a long press anywhere on the row
    /// enters selection mode. The two gestures sit on nested views (tap inside, long press outside)
    /// the way the Inbox rows do, so neither swallows the other. Swipe actions stand down while
    /// selecting: they act on one document, which reads as a mistake mid-selection.
    @ViewBuilder
    private func documentRow(_ doc: Document) -> some View {
        HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: selected.contains(doc.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(selected.contains(doc.id) ? WW.moss : WW.inkTertiary)
            }
            DocumentRow(document: doc)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !selectionMode {
                // Stands in for the disclosure indicator a NavigationLink would have drawn.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WW.inkTertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selectionMode { toggle(doc.id) } else { path.append(.document(doc.id)) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onLongPressGesture { enterSelection(with: doc.id) }
        .wwRow()
        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .swipeActions(edge: .trailing) {
            if !selectionMode {
                Button("Delete", role: .destructive) { model.documents.moveToTrash(doc) }
                    .tint(WW.ember)
                Button("Rename") { startRename(doc) }.tint(WW.slate)
                Button(doc.isPinned ? "Unpin" : "Pin") {
                    model.documents.setPinned(!doc.isPinned, for: doc.id)
                }.tint(WW.amber)
            }
        }
        .swipeActions(edge: .leading) {
            if !selectionMode {
                Button("Copy") { copy(doc) }.tint(WW.inkTertiary)
                Button("Share") { shareItem = ShareItem(text: doc.combinedText) }.tint(WW.violet)
                Button("Edit") { startEdit(doc) }.tint(WW.slate)
            }
        }
    }

    // MARK: Selection mode

    private func enterSelection(with id: UUID) {
        guard !selectionMode else { return }
        withAnimation(.snappy(duration: 0.22)) {
            selectionMode = true
            selected = [id]
        }
    }

    private func exitSelection() {
        withAnimation(.snappy(duration: 0.22)) {
            selectionMode = false
            selected = []
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func selectAll() {
        let all = Set(userDocuments.map(\.id))
        selected = (selected == all) ? [] : all
    }

    /// True when every selected document is already pinned — the batch button then reads "Unpin"
    /// and clears them instead, the way the single-document swipe action flips.
    private var allSelectedArePinned: Bool {
        !selectedDocuments.isEmpty && selectedDocuments.allSatisfy(\.isPinned)
    }

    private func pinSelected() {
        model.documents.setPinned(!allSelectedArePinned, for: selected)
        exitSelection()
    }

    private func deleteSelected() {
        let count = selected.count
        model.documents.moveToTrash(selected)
        wwLog("Moved \(count) document\(count == 1 ? "" : "s") to the trash", .general)
        exitSelection()
    }

    /// Copy the selection as one Markdown file — each document's title as a heading over its body,
    /// blank-line separated, the same rendering the backup folder writes.
    private func copySelected() {
        let count = selected.count
        #if canImport(UIKit)
        UIPasteboard.general.string = MarkdownBackup.combined(selectedDocuments)
        #endif
        wwLog("Copied \(count) document\(count == 1 ? "" : "s") to clipboard", .general)
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
