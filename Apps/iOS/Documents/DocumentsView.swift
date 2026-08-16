import SwiftUI
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

struct DocumentsView: View {
    @EnvironmentObject private var model: AppModel
    /// "Open this document" requests arriving from outside the app (the Recent Documents widget).
    @ObservedObject private var opener = DocumentLauncher.shared
    @State private var renameTarget: Document?
    @State private var renameText = ""
    // The New Document dialog: a title and the Document / Graph toggle, which is the one thing
    // about a document that can't be changed afterwards.
    @State private var showingNewDocument = false
    @State private var newDocumentTitle = ""
    @State private var newDocumentKind: Document.Kind = .document
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
                destination(for: route)
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
                            newDocumentTitle = ""
                            newDocumentKind = .document
                            showingNewDocument = true
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
                                 message: "Tap ✎ to start a document — or a graph — or the mic to record straight to your Inbox. Watch recordings land in the Inbox tab.")
                }
            }
            .sheet(isPresented: $showingNewDocument) {
                NewDocumentSheet(title: $newDocumentTitle, kind: $newDocumentKind) {
                    createDocument()
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
            // Widget deep link: both hooks are needed — onChange for requests while this tab is
            // visible, onAppear for one that switched tabs before this view existed (the pending
            // id waits in the launcher until then).
            .onChange(of: opener.pendingDocumentID) { openPendingDocument() }
            .onAppear { openPendingDocument() }
        }
    }

    /// Where a pushed route lands. A graph opens onto its canvas rather than the paragraph list —
    /// picked by the document's own kind, so every way in (a row, the widget's deep link) agrees.
    ///
    /// Its own function rather than a closure body: the destination builder sits inside an already
    /// long chain of modifiers, and leaving a two-branch conditional in there gives the type checker
    /// the whole list to solve at once.
    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .document(let id):
            let isGraph = model.documents.document(with: id)?.isGraph ?? false
            if isGraph {
                GraphDocumentView(documentID: id)
            } else {
                DocumentDetailView(documentID: id)
            }
        case .trash:
            TrashView()
        }
    }

    /// Push the document a widget tap asked for, replacing whatever was on the stack. Skips ids
    /// that no longer exist (deleted or trashed since the widget snapshot was taken) — the list
    /// itself is the sensible landing spot then.
    private func openPendingDocument() {
        guard let id = opener.pendingDocumentID else { return }
        opener.pendingDocumentID = nil
        guard model.documents.document(with: id) != nil else { return }
        if selectionMode { exitSelection() }
        path = [.document(id)]
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
                // Copy and Share hand over the body as text either way — for a graph that's its
                // outline. Edit is the one action a graph has no answer to: there's no column of
                // text to open, and writing one back would quietly bury the canvas.
                Button("Copy") { copy(doc) }.tint(WW.inkTertiary)
                Button("Share") { shareItem = ShareItem(text: doc.combinedText) }.tint(WW.violet)
                if !doc.isGraph {
                    Button("Edit") { startEdit(doc) }.tint(WW.slate)
                }
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

    /// Confirm the New Document dialog: create the document (or the graph) under the typed title,
    /// falling back to a name of its own kind when nothing was typed.
    private func createDocument() {
        let trimmed = newDocumentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = newDocumentKind == .graph ? "New Graph" : "New Document"
        let doc = model.documents.createDocument(title: trimmed.isEmpty ? fallback : trimmed,
                                                 kind: newDocumentKind)
        wwLog("Created \(newDocumentKind == .graph ? "graph" : "document") “\(doc.title)”", .general)
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

/// The dialog behind the ✎ button: name the thing, and choose what it is.
///
/// The toggle is here rather than on the document itself because it's the one decision that can't
/// be revisited — a graph and a document have different bodies, so there's nothing sensible to
/// convert between them.
private struct NewDocumentSheet: View {
    @Binding var title: String
    @Binding var kind: Document.Kind
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Kind", selection: $kind) {
                    Text("Document").tag(Document.Kind.document)
                    Text("Graph").tag(Document.Kind.graph)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: $title)
                        .font(WW.rowTitle)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { create() }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(WW.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(WW.hairline, lineWidth: 1))
                    WWFooter(kind == .graph
                             ? "A pannable canvas of nodes. Hold anywhere on it to record a node; double-tap to type one. Exports as a Markdown outline."
                             : "Paragraphs, read top to bottom. Record into it, import text, and transform what's there.")
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wwContentWidth()
            .background(WW.paper)
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create() } }
            }
        }
        .presentationDetents([.height(300)])
        .onAppear { titleFocused = true }
    }

    private func create() {
        onCreate()
        dismiss()
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
                // A graph says so in the list: it opens onto a canvas, not a page.
                if document.isGraph {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11))
                        .foregroundStyle(WW.inkSecondary)
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
        let body: String
        if document.isGraph {
            let nodes = document.nodes.count
            body = "\(nodes) node\(nodes == 1 ? "" : "s")"
        } else {
            let paras = document.paragraphs.count
            body = "\(paras) paragraph\(paras == 1 ? "" : "s")"
        }
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
