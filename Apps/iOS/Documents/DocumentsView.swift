import SwiftUI
import AVFoundation
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

    // Hold-to-record from a row's "+": the recorder behind it, and which document is being spoken
    // into right now. One at a time — it's one finger on one button.
    @StateObject private var recorder = AudioRecorder()
    @State private var recordingDocumentID: UUID?
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
    /// Everything the list is *about*: not the Inbox, and not the second half of a joint document —
    /// that one is reached through the half it was made from, which is the row you see.
    private var userDocuments: [Document] {
        let followers = Document.jointFollowerIDs(in: allDocuments)
        return allDocuments.filter {
            $0.title != DocumentStore.inboxTitle && !followers.contains($0.id)
        }
    }
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
            // A hold whose finger never came back — a tab switched away mid-recording — is filed
            // rather than left running behind the list.
            .onDisappear { finishHoldRecording() }
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
            // A joint document opens as both halves at once; either half on its own opens as itself.
            if let partner = model.documents.jointPartnerID(of: id) {
                JointDocumentView(documentID: id, partnerID: partner)
            } else if model.documents.document(with: id)?.isGraph ?? false {
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
    /// Tap the row to open the document — or to toggle it while selecting — and long-press it to
    /// enter selection mode. Both live on the row's *text*, not the whole line, so the "+" beside
    /// the open arrow keeps its own press: holding it records, and neither of the row's gestures has
    /// any claim on that touch. Swipe actions stand down while selecting: they act on one document,
    /// which reads as a mistake mid-selection.
    @ViewBuilder
    private func documentRow(_ doc: Document) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if selectionMode {
                    Image(systemName: selected.contains(doc.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(selected.contains(doc.id) ? WW.moss : WW.inkTertiary)
                }
                DocumentRow(document: doc, recordingElapsed: recordingElapsed(for: doc),
                            partner: jointPartner(of: doc))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selectionMode { toggle(doc.id) } else { open(doc.id) }
            }
            .onLongPressGesture { enterSelection(with: doc.id) }

            if !selectionMode {
                // The graph canvas's "+", on a list row: hold it and you're recording into this
                // document without opening it; let go and the words are on their way.
                HoldablePlusButton(onTap: { open(doc.id) },
                                   onHold: { beginHoldRecording(into: doc) },
                                   onRelease: { finishHoldRecording() })
                    .accessibilityLabel("Record into \(doc.title)")
                // Stands in for the disclosure indicator a NavigationLink would have drawn.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WW.inkTertiary)
                    .contentShape(Rectangle())
                    .onTapGesture { open(doc.id) }
            }
        }
        .padding(.vertical, 2)
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

    /// The half this row's document is joined to, if it's half of a joint document.
    private func jointPartner(of doc: Document) -> Document? {
        guard let id = model.documents.jointPartnerID(of: doc.id) else { return nil }
        return model.documents.document(with: id)
    }

    /// Push a document onto the stack, unless it's already the top of it. The row, the "+" and the
    /// open arrow all lead to the same place, so two taps in quick succession shouldn't be able to
    /// stack a document on itself.
    private func open(_ id: UUID) {
        guard path.last != .document(id) else { return }
        path.append(.document(id))
    }

    // MARK: Holding a row's "+" to record

    /// Whether this row is the one being spoken into, and for how long so far — the row carries the
    /// counter where its subtitle usually goes, since the button itself is under a fingertip.
    private func recordingElapsed(for doc: Document) -> TimeInterval? {
        recordingDocumentID == doc.id ? recorder.elapsed : nil
    }

    /// The "+" has been held: start capturing. Nothing is written down yet — a document doesn't get
    /// an empty item because a finger rested on a button — the clip is filed when the finger lifts.
    private func beginHoldRecording(into doc: Document) {
        guard canRecord() else { return }
        do {
            try recorder.start(to: model.documents.newAudioURL().url)
        } catch {
            model.setupError = error.localizedDescription
            return
        }
        recordingDocumentID = doc.id
        WWHaptics.recordingStarted()
    }

    /// The finger lifted: file the clip against the document it was spoken into, and let
    /// transcription run on its own — appended to the body of an ordinary document, or dropped into
    /// a fresh root node of a graph, which is that document's version of one more item.
    private func finishHoldRecording() {
        guard let documentID = recordingDocumentID else { return }
        recordingDocumentID = nil
        guard let result = recorder.stop() else { return }
        // A press let go the instant it's recognised isn't a recording — and a document deleted
        // out from under the hold has nowhere to put one.
        guard result.duration >= GraphCanvas.minimumClip,
              let doc = model.documents.document(with: documentID) else {
            try? FileManager.default.removeItem(at: result.url)
            return
        }
        if doc.isGraph {
            guard let node = model.documents.addRootNode(in: documentID) else {
                try? FileManager.default.removeItem(at: result.url)
                return
            }
            model.captureGraphNode(audioURL: result.url, duration: result.duration,
                                   nodeID: node.id, in: documentID)
        } else {
            model.addDeviceRecording(audioURL: result.url, duration: result.duration,
                                     toDocument: documentID, body: .append)
        }
        haptic()
        wwLog("Recorded into “\(doc.title)” from the documents list", .general)
    }

    /// Whether capture can start this instant.
    ///
    /// Permission is *checked*, never awaited: by the time a hold is recognised the finger is
    /// already down, so an await here would be a beat of silence at the head of every clip. Asking
    /// is a separate path, taken once, on the first hold of the app's life.
    private func canRecord() -> Bool {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            Task { @MainActor in
                let granted = await recorder.requestPermission()
                if !granted {
                    model.setupError = "Microphone permission is required to record."
                }
            }
            return false
        }
        return true
    }

    private func haptic() { WWHaptics.medium() }

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
    /// How long the hold on this row's "+" has been running, if it's the one recording.
    var recordingElapsed: TimeInterval?
    /// The other half, when this row is a joint document — so the row can say it opens onto two
    /// things rather than one, and count what's in both.
    var partner: Document?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if document.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WW.moss)
                }
                // A graph says so in the list: it opens onto a canvas, not a page. A joint document
                // says so too — it opens onto both at once.
                if partner != nil {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 11))
                        .foregroundStyle(WW.moss)
                } else if document.isGraph {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11))
                        .foregroundStyle(WW.inkSecondary)
                }
                Text(document.title)
                    .font(WW.rowTitle)
                    .foregroundStyle(WW.ink)
            }
            // While the "+" is held, the counter takes the subtitle's place: the button is under a
            // fingertip, so the one thing worth watching is put where it can be seen.
            if let recordingElapsed {
                HStack(spacing: 6) {
                    Circle().fill(WW.ember).frame(width: 8, height: 8)
                    Text(Recording.durationLabel(recordingElapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WW.ink)
                    Text("Recording")
                        .font(.caption)
                        .foregroundStyle(WW.inkSecondary)
                }
            } else {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(WW.inkSecondary)
            }
        }
    }
    private var subtitle: String {
        // A joint document reads as what it holds on both sides — "4 paragraphs · 7 nodes" — since
        // one row stands for the pair.
        let halves = [document, partner].compactMap { $0 }
        let body = halves.map(Self.bodyCount).joined(separator: " · ")
        let count = halves.reduce(0) { $0 + $1.recordings.count }
        let clips = count == 0 ? "" : " · \(count) recording\(count == 1 ? "" : "s")"
        return body + clips
    }

    private static func bodyCount(of document: Document) -> String {
        if document.isGraph {
            let nodes = document.nodes.count
            return "\(nodes) node\(nodes == 1 ? "" : "s")"
        }
        let paras = document.paragraphs.count
        return "\(paras) paragraph\(paras == 1 ? "" : "s")"
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
