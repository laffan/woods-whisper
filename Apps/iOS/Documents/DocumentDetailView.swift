import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
// The subclass header, for the passive recognizer that reads the ⌘ key off a touch: overriding
// `touchesBegan` and setting `state` are only visible with it imported.
import UIKit.UIGestureRecognizerSubclass
#endif
#if canImport(GameController)
// For the hardware ⌘ and ⌥ as they're *held* — see `ModifierKeyMonitor`. GameController reports the
// state of the keys on the device, which is the one place iOS will tell you that.
import GameController
#endif

/// A document: a coherent body of editable paragraphs, with the source recordings kept in a
/// separate "Recordings" section at the bottom.
///
/// • The body reads top-to-bottom. Between paragraphs, a "+" inserts a fresh recording's transcript
///   at that spot. Swipe a paragraph for Delete / Revise / Edit / Transform; long-press to enter
///   reorder mode and drag to rearrange. A "Revise" clip is set aside in a "Revisions" section.
/// • Recordings are source material: play them, or "Re-transcribe" to append their text to the body.
///   Long-press a recording to enter selection mode for batch actions.
/// • "Transform" rewrites the whole body in place.
struct DocumentDetailView: View {
    @EnvironmentObject private var model: AppModel
    /// The size transcription text is set in (Settings → Display) — the body's paragraphs here.
    @Environment(\.transcriptTextSize) private var transcriptTextSize: Double
    let documentID: UUID
    /// True when this is one pane of a joint document rather than a screen of its own: it draws its
    /// own header instead of filling in a navigation bar it doesn't have, and puts nothing in the
    /// bar the pair sits under (which the other half would be fighting it for).
    var isEmbedded = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Where the Auto transform strip goes. Pinned to the bottom everywhere except one place: half
    /// of a joint document on a phone, where two panes are sharing the height and a strip pinned to
    /// each takes more of it than the writing does. There it sits in the list under the document's
    /// own actions and scrolls away with them.
    private var showsInlineAutoTransform: Bool { isEmbedded && sizeClass == .compact }

    // Body & recordings reorder (long-press → drag to rearrange)
    @State private var editMode: EditMode = .inactive

    // Recording → document move (swipe a recording right)
    @State private var movingRecording: Recording?

    // Transform
    @State private var showingDocTransform = false        // drives the bottom transform pane
    @State private var expandedPresetID: UUID?            // which preset row is twirled open
    @State private var editingPreset: PromptPreset?       // "Edit" from a pane row
    @State private var paragraphTransformTarget: UUID?
    @State private var isTransformingDoc = false
    @State private var transformingParagraphID: UUID?

    // Paragraph editing — in place, in the list. `editingText` / `editingSelection` are the live
    // buffer and caret for the paragraph identified by `editingParagraphID`.
    @State private var editingParagraphID: UUID?
    @State private var editingText = ""
    @State private var editingSelection = NSRange(location: 0, length: 0)

    // Whole-document editing (the "Edit" action)
    @State private var showingDocEditor = false
    @State private var docEditorText = ""

    // Share
    @State private var shareItem: ShareItem?
    @State private var audioShareItem: AudioShareItem?
    @State private var documentFileShare: DocumentFileShareItem?

    // Document rename (tap the title)
    @State private var showingRename = false
    @State private var renameText = ""

    // Reset-with-originals confirmation
    @State private var showingResetConfirm = false

    // Inline "Add New Transform" (save a preset and run it at once)
    @State private var creatingTransform: PromptPreset?

    // Recording flows (insert / replace / re-record / add) routed through one sheet
    @State private var recorderTask: RecorderTask?

    // "Import Text File…" from the overflow menu
    @State private var showingTextImporter = false

    // Playback
    @StateObject private var playback = AudioPlaybackController()

    /// The hardware ⌘ as it's held. Watched here for one thing: it turns the inter-paragraph "+"
    /// from "record a section here" into "type one here" — the graph canvas's double-tap, on a
    /// document. Read as *state* rather than off a touch, because the button has to say so before
    /// it's pressed. (With no keyboard attached it stays false and the "+" is the recorder it has
    /// always been; a document has no on-screen ⌘ the way the canvas does.)
    @ObservedObject private var modifierKeys = ModifierKeyMonitor.shared

    private var document: Document? { model.documents.document(with: documentID) }

    var body: some View {
        Group {
            if let document {
                content(for: document)
            } else {
                WWEmptyState(title: "Document not found", systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WW.paper)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isEmbedded { paneMenu(for: document) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !isEmbedded { toolbarContent(for: document) } }
        .onAppear { playback.onError = { message in model.setupError = message } }
        // Leaving the document commits an open in-place edit rather than dropping it.
        .onDisappear {
            playback.stop()
            finishEditing()
        }
        .sheet(item: $recorderTask) { task in
            RecordingSheet(title: task.sheetTitle,
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                complete(task, url: url, duration: duration)
            }
        }
        .sheet(isPresented: $showingDocEditor) {
            TextEditorSheet(title: "Edit Document", text: $docEditorText) {
                model.documents.setParagraphs(Document.paragraphs(from: docEditorText), in: documentID)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.text])
        }
        .sheet(item: $audioShareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .sheet(item: $documentFileShare) { item in
            ActivityView(activityItems: [item.url])
        }
        .fileImporter(isPresented: $showingTextImporter,
                      allowedContentTypes: TextImportItems.contentTypes,
                      onCompletion: importTextFile)
        .confirmationDialog("Move recording to…",
                            isPresented: Binding(get: { movingRecording != nil },
                                                 set: { if !$0 { movingRecording = nil } }),
                            titleVisibility: .visible) {
            ForEach(otherDocuments) { target in
                Button(target.title) {
                    if let rec = movingRecording {
                        model.documents.moveRecording(rec.id, from: documentID, to: target.id)
                    }
                    movingRecording = nil
                }
            }
        }
        .alert("Rename document", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let document, !trimmed.isEmpty { model.documents.rename(document, to: trimmed) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Reset with Originals?", isPresented: $showingResetConfirm) {
            Button("Reset", role: .destructive) { model.resetWithOriginals(in: documentID) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This replaces the document with the recordings' original transcripts and will delete any edits and transformations you've made.")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for document: Document) -> some View {
        List {
            bodySection(for: document)
            documentActionsSection(for: document)
            // On a phone, half of a joint document carries its Auto transform strip here — under
            // the row of actions it belongs beside — rather than pinned to the bottom of a pane
            // that's only half a screen tall.
            if showsInlineAutoTransform {
                Section {
                    AutoTransformBar(presets: model.documents.presets,
                                     selected: model.autoTransformPreset(for: documentID),
                                     onSelect: { model.setAutoTransform($0, for: documentID) })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            recordingsSection(for: document)
        }
        .wwList()
        .environment(\.editMode, $editMode)
        // Bottom furniture: the record button and the Auto transform toggle. It stands down while
        // the list is in reorder mode (the toolbar's own Done is the way out) and while a paragraph
        // is being edited, where the actions ride inside the edit box instead.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editingParagraphID == nil && !editMode.isEditing {
                CaptureBar(presets: model.documents.presets,
                           selected: model.autoTransformPreset(for: documentID),
                           onSelect: { model.setAutoTransform($0, for: documentID) },
                           onRecord: { recorderTask = .addToRecordings },
                           showsAutoTransform: !showsInlineAutoTransform)
            }
        }
        .overlay(alignment: .top) {
            if isTransformingDoc {
                // A reasoning model spends its first stretch thinking, with no answer text yet —
                // saying "Transforming…" through all of it reads as a stall.
                BusyBanner(message: model.isThinking(documentID) ? "Thinking…"
                                                                 : "Transforming document…")
                    .padding(.top, 8)
            }
        }
        .overlay {
            if showingDocTransform {
                transformOverlay(for: document)
            } else if paragraphTransformTarget != nil {
                paragraphTransformOverlay()
            }
        }
        .sheet(item: $creatingTransform) { preset in
            PresetEditorView(preset: preset, isNew: true, saveTitle: "Save & Run") { saved in
                runDocumentTransform(saved, on: document)
            }
        }
        .sheet(item: $editingPreset) { preset in
            PresetEditorView(preset: preset, isNew: false)
        }
    }

    // MARK: Body section (paragraphs)

    @ViewBuilder
    private func bodySection(for document: Document) -> some View {
        Section {
            if document.paragraphs.isEmpty {
                Text("No text yet. Tap “+” to record straight into the document, or “Re-transcribe” a recording below to add its text here.")
                    .font(.callout).foregroundStyle(WW.inkSecondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                InsertHereButton(isRecording: recorderTask == .insertBody(at: 0),
                                 makesTextSection: modifierKeys.commandDown) {
                    startInsert(at: 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                if !editMode.isEditing {
                    InsertHereButton(isRecording: recorderTask == .insertBody(at: 0),
                                     makesTextSection: modifierKeys.commandDown) {
                        startInsert(at: 0)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
                ForEach(document.paragraphs) { para in
                    let position = (document.paragraphs.firstIndex(of: para) ?? 0) + 1
                    paragraphRow(para, position: position)
                }
                .onMove { offsets, destination in
                    model.documents.moveParagraphs(in: documentID, from: offsets, to: destination)
                }

                // Breathing room below the document body.
                Color.clear
                    .frame(height: 28)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    /// One paragraph of the body, with the inter-paragraph "+" beneath it.
    ///
    /// The paragraph being edited drops every gesture the others carry: its row *is* the editor, so
    /// a double tap belongs to the text view (select a word), a long press to the selection handles,
    /// and a swipe to the caret — not to reorder, delete, or revise.
    @ViewBuilder
    private func paragraphRow(_ para: Document.Paragraph, position: Int) -> some View {
        let isEditing = editingParagraphID == para.id
        let row = VStack(alignment: .leading, spacing: 10) {
            paragraphContent(para)
            // The "+" stays under the paragraph you're editing: adding a section below what you're
            // working on is exactly when you want it.
            if !editMode.isEditing {
                InsertHereButton(isRecording: recorderTask == .insertBody(at: position),
                                 makesTextSection: modifierKeys.commandDown) {
                    startInsert(at: position)
                }
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))

        if isEditing {
            row
        } else {
            row
                .onTapGesture(count: 2) {
                    guard !editMode.isEditing else { return }
                    startEditing(para)
                }
                .onLongPressGesture {
                    withAnimation { editMode = .active }
                }
                // Swipe left → Replace / Delete
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) {
                        model.documents.deleteParagraph(para.id, in: documentID)
                    }
                    .tint(WW.ember)
                    Button("Revise") { recorderTask = .revise(paragraphID: para.id) }.tint(WW.amber)
                }
                // Swipe right → Transform / Edit
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button("Transform") {
                        withAnimation(.snappy(duration: 0.22)) { paragraphTransformTarget = para.id }
                    }.tint(WW.violet)
                    Button("Edit") { startEditing(para) }.tint(WW.slate)
                }
        }
    }

    @ViewBuilder
    private func paragraphContent(_ para: Document.Paragraph) -> some View {
        if editingParagraphID == para.id {
            paragraphEditBox()
                .padding(.vertical, 6)
        } else if transformingParagraphID == para.id {
            HStack(spacing: 8) {
                ProgressView()
                Text(model.isThinking(para.id) ? "Thinking…" : "Transforming…")
                    .foregroundStyle(WW.inkSecondary)
            }
        } else {
            Text(para.text)
                .font(InlineTextStyle.documentBody.font(transcriptTextSize))
                .lineSpacing(5)
                .foregroundStyle(WW.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Document actions (Copy / Share / Edit)

    @ViewBuilder
    private func documentActionsSection(for document: Document) -> some View {
        if document.hasBodyText {
            Section {
                VStack(spacing: 10) {
                    WWHairline()
                    HStack(spacing: 0) {
                        docActionButton("Copy", "doc.on.doc") { copyDocument(document) }
                        docActionButton("Share", "square.and.arrow.up") {
                            shareItem = ShareItem(text: document.combinedText)
                        }
                        docActionButton("Edit", "pencil") {
                            docEditorText = document.combinedText
                            showingDocEditor = true
                        }
                        docActionButton("Transform", "wand.and.stars") {
                            withAnimation(.snappy(duration: 0.22)) { showingDocTransform = true }
                        }
                        .disabled(!model.modelReady || isTransformingDoc)
                    }
                    WWHairline()
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            }
        }
    }

    private func docActionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .regular))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(WW.moss)
    }

    // MARK: Recordings section

    @ViewBuilder
    private func recordingsSection(for document: Document) -> some View {
        let originals = document.recordings.filter { !$0.isRevision }
        let revisions = document.recordings.filter { $0.isRevision }

        if !originals.isEmpty {
            Section {
                ForEach(originals) { recordingRow($0) }
                .onMove { offsets, destination in
                    model.documents.moveRecordings(in: documentID, isRevision: false,
                                                   from: offsets, to: destination)
                }
            } header: {
                WWSectionHeader("Recordings")
            }
        }

        if !revisions.isEmpty {
            Section {
                ForEach(revisions) { recordingRow($0) }
                .onMove { offsets, destination in
                    model.documents.moveRecordings(in: documentID, isRevision: true,
                                                   from: offsets, to: destination)
                }
            } header: {
                WWSectionHeader("Revisions")
            }
        }

        if !document.recordings.isEmpty {
            if document.recordings.contains(where: { $0.transcript?.isEmpty == false }) {
                Section {
                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Label("Reset with Originals", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(WW.ember)
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } footer: {
                    WWFooter("Replaces the document body with the recordings' original transcripts, discarding edits and transforms.")
                }
            }
        }
    }

    /// One row in the Recordings (or Revisions) section: the play control + transcript, plus the
    /// swipe actions shared by both sections.
    @ViewBuilder
    private func recordingRow(_ recording: Recording) -> some View {
        RecordingRow(
            recording: recording,
            isActive: playback.playingID == recording.id,
            isPaused: playback.isPaused,
            onPlay: { playback.toggle(recording, url: model.documents.audioURL(for: recording)) }
        )
        .wwRow()
        .onLongPressGesture { withAnimation { editMode = .active } }
        // Swipe left → Delete / Share the audio file. An entry that came in as text has no clip to
        // share (or to re-run speech-to-text over, below).
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) {
                model.documents.deleteRecording(recording.id, fromDocument: documentID)
            }
            .tint(WW.ember)
            if !recording.isTextOnly {
                Button("Share") {
                    audioShareItem = AudioShareItem(url: model.documents.audioURL(for: recording))
                }.tint(WW.violet)
            }
        }
        // Swipe right → Transcribe (re-run STT) / Append its transcript to the body / Move
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !recording.isTextOnly {
                Button("Transcribe") {
                    Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) }
                }.tint(WW.slate)
            }
            Button("Append") {
                model.appendRecordingToBody(recordingID: recording.id, in: documentID)
            }.tint(WW.moss)
            if !otherDocuments.isEmpty {
                Button("Move") { movingRecording = recording }.tint(WW.amber)
            }
        }
    }

    private var otherDocuments: [Document] {
        model.documents.documents.filter { $0.id != documentID && $0.title != DocumentStore.inboxTitle }
    }

    private func copyDocument(_ document: Document) {
        #if canImport(UIKit)
        UIPasteboard.general.string = document.combinedText
        #endif
        wwLog("Copied “\(document.title)” to clipboard", .general)
    }

    // MARK: Toolbar

    /// The title, tappable to rename — the same control whether it's sitting in a navigation bar or
    /// in the header a pane of a joint document draws for itself.
    private func titleButton(for document: Document?) -> some View {
        Button {
            renameText = document?.title ?? ""
            showingRename = true
        } label: {
            Text(document?.title ?? "Document")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WW.ink)
                .lineLimit(1)
        }
    }

    /// What's in the **⋯** menu. Kept apart from where it's *put* for the same reason.
    @ViewBuilder
    private func menuContent(for document: Document) -> some View {
        TextImportItems(onClipboard: importFromClipboard,
                        onFile: { showingTextImporter = true })
        Divider()
        Button { shareDocumentFile(document) } label: {
            Label("Share as Woods Whisper File", systemImage: "arrow.up.doc")
        }
        JointDocumentMenuItem(isJoined: isJoined,
                              onCreate: createJointCounterpart,
                              onSeparate: separateJoint)
        // Half of a pair has no title to tap, so the rename lives here instead.
        if isEmbedded {
            Divider()
            Button {
                renameText = document.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
    }

    /// The **⋯** a pane floats in its own top-right corner when it's half of a joint document.
    ///
    /// No title and no strip across the top: a pane is half a screen, and a title bar on each would
    /// spend a good part of that saying what the row you tapped already said. So the menu goes where
    /// the navigation bar's would be — a plate over the corner of the content, the way the canvas
    /// floats its own controls — and the rename that used to live in the title moves *into* it,
    /// since that's now the only place it could be.
    @ViewBuilder
    private func paneMenu(for document: Document?) -> some View {
        Group {
            if editMode.isEditing {
                Button("Done") { withAnimation { editMode = .inactive } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WW.moss)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(WW.surface.opacity(0.94), in: Capsule())
                    .overlay(Capsule().stroke(WW.hairline, lineWidth: 1))
            } else if let document {
                Menu { menuContent(for: document) } label: { paneMenuGlyph }
            }
        }
        .shadow(color: .black.opacity(0.10), radius: 10, y: 2)
        .padding(.top, 8)
        .padding(.trailing, 12)
    }

    private var paneMenuGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(WW.moss)
            .frame(width: 34, height: 34)
            .background(WW.surface.opacity(0.94), in: Circle())
            .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
            .contentShape(Circle())
    }

    @ToolbarContentBuilder
    private func toolbarContent(for document: Document?) -> some ToolbarContent {
        // Tappable document title — opens the rename editor.
        ToolbarItem(placement: .principal) {
            titleButton(for: document)
        }

        if editMode.isEditing {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { withAnimation { editMode = .inactive } }
            }
        } else {
            // No mic up here any more: recording is the red button above the bottom bar.
            if let document {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        menuContent(for: document)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: Joint document

    /// Whether this document is half of a pair.
    private var isJoined: Bool { model.documents.jointPartnerID(of: documentID) != nil }

    /// "Create Joint Document": make the graph half. Nothing is pushed — this screen *becomes* the
    /// pair, because the route that opened it (`Route.document`) asks the store each time whether
    /// that document has a partner, and now it has. Pushing instead would mean a second navigation
    /// style in a stack driven by a typed path, which SwiftUI treats as a fatal mismatch.
    private func createJointCounterpart() {
        guard let counterpart = model.documents.createJointCounterpart(for: documentID) else { return }
        wwLog("Joined “\(counterpart.title)” to a new graph", .general)
    }

    /// "Separate Joint Document": the halves go their own ways, both keeping everything in them.
    private func separateJoint() {
        model.documents.separateJoint(documentID)
        wwLog("Separated a joint document", .general)
    }

    /// Export the document (audio + edited transcriptions) as a single `.wwdoc` file and present the
    /// share sheet so it can be sent to another device.
    private func shareDocumentFile(_ document: Document) {
        if let url = model.exportDocumentFile(document.id) {
            documentFileShare = DocumentFileShareItem(url: url)
        }
    }

    // MARK: Importing text

    /// Append whatever is on the clipboard to the document body, split into paragraphs.
    private func importFromClipboard() {
        guard let text = model.clipboardText() else { return }
        model.importText(text, intoDocument: documentID)
    }

    /// Append a picked text file's contents to the document body.
    private func importTextFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard let text = model.importedText(from: url) else { return }
            model.importText(text, intoDocument: documentID)
        case .failure(let error):
            model.setupError = "Couldn't open that file: \(error.localizedDescription)"
        }
    }

    // MARK: Transform pane

    private var transformHeader: String { "Transform — \(AppSettings.shared.model.shortName)" }

    /// Document transform: runs the chosen preset over the whole body; rows expose Duplicate / Edit.
    @ViewBuilder
    private func transformOverlay(for document: Document) -> some View {
        transformOverlay(editing: true, dismiss: { showingDocTransform = false }) { preset in
            showingDocTransform = false
            runDocumentTransform(preset, on: document)
        }
    }

    /// Paragraph transform (swipe → Transform): same pane, but runs over the one paragraph and omits
    /// the row editing affordances.
    @ViewBuilder
    private func paragraphTransformOverlay() -> some View {
        transformOverlay(editing: false, dismiss: { paragraphTransformTarget = nil }) { preset in
            let pid = paragraphTransformTarget
            paragraphTransformTarget = nil
            if let pid { runParagraphTransform(preset, paragraphID: pid) }
        }
    }

    /// Floating pane: a dimmed scrim (tap anywhere outside to dismiss) with the pane anchored at the
    /// bottom. `editing` controls whether the per-row Duplicate / Edit and "Add New" are shown.
    @ViewBuilder
    private func transformOverlay(editing: Bool,
                                  dismiss: @escaping () -> Void,
                                  run: @escaping (PromptPreset) -> Void) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy(duration: 0.22)) { dismiss() } }
            transformPane(editing: editing, dismiss: dismiss, run: run)
                .wwPane()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The pane body: a "Transform — <model>" header (kept on one line so a long model name widens
    /// the pane rather than wrapping), one row per preset, then optionally "Add New Transform…".
    @ViewBuilder
    private func transformPane(editing: Bool,
                               dismiss: @escaping () -> Void,
                               run: @escaping (PromptPreset) -> Void) -> some View {
        VStack(spacing: 0) {
            Text(transformHeader)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WW.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            WWHairline()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.documents.presets) { preset in
                        transformRow(preset, editing: editing, run: run)
                        WWHairline().padding(.leading, 16)
                    }
                    if editing {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { dismiss() }
                            creatingTransform = PromptPreset(name: "", template: PromptPreset.transcriptToken)
                        } label: {
                            Label("Add New Transform…", systemImage: "plus")
                                .foregroundStyle(WW.moss)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    @ViewBuilder
    private func transformRow(_ preset: PromptPreset,
                              editing: Bool,
                              run: @escaping (PromptPreset) -> Void) -> some View {
        let isExpanded = expandedPresetID == preset.id
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Main action: run this transform.
                Button {
                    withAnimation(.snappy(duration: 0.22)) { run(preset) }
                } label: {
                    Text(preset.name)
                        .foregroundStyle(WW.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if editing {
                    // Twirl-down: reveal the prompt + Duplicate / Edit.
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            expandedPresetID = isExpanded ? nil : preset.id
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .medium))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                            .foregroundStyle(WW.inkTertiary)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if editing && isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(preset.template)
                        .font(.caption)
                        .foregroundStyle(WW.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 16) {
                        Button {
                            duplicatePreset(preset)
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { showingDocTransform = false }
                            editingPreset = preset
                        } label: { Label("Edit", systemImage: "pencil") }
                        Spacer()
                    }
                    .font(.callout)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    // MARK: Transform actions

    private func runDocumentTransform(_ preset: PromptPreset, on document: Document) {
        isTransformingDoc = true
        Task {
            await model.transformDocument(preset, on: document)
            isTransformingDoc = false
        }
    }

    /// Duplicate a preset into a new editable copy (handy for tweaking a built-in without losing it).
    private func duplicatePreset(_ preset: PromptPreset) {
        let copy = PromptPreset(name: preset.name + " copy",
                                systemPrompt: preset.systemPrompt,
                                template: preset.template,
                                temperature: preset.temperature,
                                maxTokens: preset.maxTokens,
                                isBuiltIn: false)
        model.documents.add(preset: copy)
        wwLog("Duplicated transform “\(preset.name)”", .general)
    }

    private func runParagraphTransform(_ preset: PromptPreset, paragraphID: UUID) {
        transformingParagraphID = paragraphID
        Task {
            await model.transformParagraph(preset, paragraphID: paragraphID, in: documentID)
            transformingParagraphID = nil
        }
    }

    // MARK: Recording-sheet completion

    private func complete(_ task: RecorderTask, url: URL, duration: TimeInterval) {
        switch task {
        case .addToRecordings:
            model.addDeviceRecording(audioURL: url, duration: duration, toDocument: documentID,
                                     body: .append)
        case .insertBody(let position):
            model.addDeviceRecording(audioURL: url, duration: duration, toDocument: documentID,
                                     body: .at(position))
        case .revise(let paragraphID):
            model.captureRevisingParagraph(audioURL: url, duration: duration,
                                           paragraphID: paragraphID, in: documentID)
        case .rerecord(let recordingID):
            model.rerecordRecording(recordingID, in: documentID, audioURL: url, duration: duration)
        case .insertAtCaret(let paragraphID, let caret, let baseText):
            Task {
                let transcript = await model.captureForInsertion(audioURL: url, duration: duration,
                                                                 in: documentID)
                // Always write back the user's in-progress edits; splice the transcript in when we
                // got one (so edits are never lost even if nothing transcribed).
                let newText = transcript.map { Self.splice(baseText, insert: $0, at: caret) } ?? baseText
                model.documents.replaceParagraph(paragraphID, in: documentID, withTextSplitInto: newText)
            }
        }
    }

    /// Insert `insert` into `base` at character offset `caret`, adding a single separating space on
    /// either side only where the neighbouring character isn't already whitespace.
    static func splice(_ base: String, insert: String, at caret: Int) -> String {
        let ns = base as NSString
        let loc = max(0, min(caret, ns.length))
        let before = ns.substring(to: loc)
        let after = ns.substring(from: loc)
        let piece = insert.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return base }
        let lead = (before.last.map { !$0.isWhitespace } ?? false) ? " " : ""
        let trail = (after.first.map { !$0.isWhitespace } ?? false) ? " " : ""
        return before + lead + piece + trail + after
    }

    // MARK: Paragraph editing (in place)

    /// The paragraph, in place, inside its outline — with the actions the editor sheet used to
    /// carry along the bottom of that same outline: Revise / Insert / Transform at the left, Done
    /// at the right.
    private func paragraphEditBox() -> some View {
        WWInlineEditBox(onDone: { finishEditing() }) {
            InlineTextEditor(text: $editingText, selection: $editingSelection, style: .documentBody)
        } actions: {
            WWInlineEditAction("Revise", "mic.fill") { reviseEditingParagraph() }
            WWInlineEditAction("Insert", "text.insert") { insertIntoEditingParagraph() }
            WWInlineEditAction("Transform", "wand.and.stars", enabled: model.modelReady) {
                transformEditingParagraph()
            }
        }
    }

    /// Tap "+": record a clip whose transcript becomes a new section at `position` — or, with **⌘
    /// held**, put an empty section there and open it for typing, which is the same thought the
    /// graph canvas answers with a double-tap. Not everything worth adding is worth saying aloud.
    ///
    /// "⌘ held" means the key *or* the ⌘ button beside a canvas's minimap: in a joint document the
    /// canvas's soft keys are the only ⌘ a device without a keyboard has, and they reach this half
    /// of the screen too (`ModifierKeyMonitor.commandDown`).
    private func startInsert(at position: Int) {
        let slot = slot(for: position)
        guard modifierKeys.commandDown else {
            recorderTask = .insertBody(at: slot)
            return
        }
        let paragraph = Document.Paragraph(text: "")
        model.documents.insertParagraphs([paragraph], at: slot, in: documentID)
        startEditing(paragraph)
    }

    /// Where a "+" tapped at `position` actually inserts, once whatever was being edited has been
    /// committed.
    ///
    /// Committing can change how many paragraphs sit above the slot (blank lines split one in two;
    /// emptying it removes it), so the slot is re-reckoned rather than trusted. Only an edit
    /// *above* the slot moves it.
    private func slot(for position: Int) -> Int {
        guard let id = editingParagraphID else { return position }
        let index = document?.paragraphs.firstIndex(where: { $0.id == id })
        let resulting = Document.paragraphs(from: editingText).count
        finishEditing()
        guard let index, index < position else { return position }
        return max(0, position + resulting - 1)
    }

    /// Open the editor on a paragraph, committing whatever was already open. The caret starts at the
    /// end of the text, so "Insert" with nothing else touched appends.
    private func startEditing(_ para: Document.Paragraph) {
        if editingParagraphID != nil { finishEditing() }
        editingText = para.text
        editingSelection = NSRange(location: (para.text as NSString).length, length: 0)
        withAnimation(.snappy(duration: 0.22)) { editingParagraphID = para.id }
    }

    /// Done: write the buffer back and close the editor. Blank lines added while editing split into
    /// separate paragraphs; emptying the text deletes it.
    private func finishEditing() {
        guard let id = editingParagraphID else { return }
        editingParagraphID = nil
        model.documents.replaceParagraph(id, in: documentID, withTextSplitInto: editingText)
    }

    /// "Revise": keep what's been typed, then record a clip that replaces the whole paragraph. Saved
    /// in place (not split) so the paragraph keeps the identity the recorder task refers to.
    private func reviseEditingParagraph() {
        guard let id = editingParagraphID else { return }
        editingParagraphID = nil
        model.documents.updateParagraph(id, in: documentID, to: editingText)
        recorderTask = .revise(paragraphID: id)
    }

    /// "Insert": record a clip and splice its transcript in at the caret. The buffer rides along with
    /// the task rather than being saved first, so the splice lands in the text as it stands on screen.
    private func insertIntoEditingParagraph() {
        guard let id = editingParagraphID else { return }
        let text = editingText
        let caret = editingSelection.location
        editingParagraphID = nil
        recorderTask = .insertAtCaret(paragraphID: id, caret: caret, baseText: text)
    }

    /// "Transform": flush the edits in place, then open the transform pane over this paragraph so the
    /// preset runs on what's on screen.
    private func transformEditingParagraph() {
        guard let id = editingParagraphID else { return }
        editingParagraphID = nil
        model.documents.updateParagraph(id, in: documentID, to: editingText)
        withAnimation(.snappy(duration: 0.22)) { paragraphTransformTarget = id }
    }

    /// What a presented `RecordingSheet` should do with the finished clip.
    enum RecorderTask: Identifiable, Equatable {
        case addToRecordings
        case insertBody(at: Int)
        case revise(paragraphID: UUID)
        case rerecord(recordingID: UUID)
        /// Record a clip, transcribe it, and splice the transcript into `baseText` at `caret`, then
        /// replace the paragraph — the editor's "Insert" action.
        case insertAtCaret(paragraphID: UUID, caret: Int, baseText: String)

        var id: String {
            switch self {
            case .addToRecordings:        return "add"
            case .insertBody(let i):      return "insert-\(i)"
            case .revise(let pid):        return "revise-\(pid)"
            case .rerecord(let rid):      return "rerecord-\(rid)"
            case .insertAtCaret(let pid, _, _): return "insert-caret-\(pid)"
            }
        }

        var sheetTitle: String {
            switch self {
            case .addToRecordings: return "New Recording"
            case .insertBody:      return "Insert Recording"
            case .revise:          return "Revise Paragraph"
            case .rerecord:        return "Re-record"
            case .insertAtCaret:   return "Insert Recording"
            }
        }
    }
}

// MARK: - Text import

/// The two "bring in text you already have" items, shared by the document overflow menu and the
/// Inbox's. Both offer the same pair — take the clipboard, or pick a text file — and differ only in
/// where the text lands, which is the owning view's business.
///
/// Lives here (rather than a standalone file) so the app target picks it up without an xcodegen
/// regen, alongside the Inbox and the recorder it's shared with.
struct TextImportItems: View {
    let onClipboard: () -> Void
    let onFile: () -> Void

    /// What the file importer will offer. `public.plain-text` covers `.txt` and `.md` (Markdown
    /// conforms to it) while keeping out formats whose bytes aren't the text — an `.rtf` or a
    /// `.docx` read as a string is markup, not writing.
    static let contentTypes: [UTType] = [.plainText]

    var body: some View {
        Button(action: onClipboard) {
            Label("Import from Clipboard", systemImage: "doc.on.clipboard")
        }
        Button(action: onFile) {
            Label("Import Text File…", systemImage: "doc.text")
        }
    }
}

// MARK: - Insert-here button

/// A minimal "insert here" affordance: a thin rule across the row with a small + at its center.
/// While a recording is being captured for this slot it turns into a red dot.
///
/// It carries more space below than above, so the rule reads as belonging to the paragraph it sits
/// under rather than floating midway between two.
///
/// With **⌘ held** it becomes a caret instead: the same slot, filled by typing rather than by
/// speaking. The glyph changes while the key is down so the button says what it will do before it's
/// pressed — which is the whole reason the document watches the key as state.
private struct InsertHereButton: View {
    var isRecording: Bool = false
    /// Whether ⌘ is down right now, so this "+" would make an empty section to type into.
    var makesTextSection: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                rule
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(tint)
                rule
            }
        }
        .buttonStyle(.plain)
        .disabled(isRecording)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .accessibilityLabel(makesTextSection ? "Add a section to type into" : "Record a section here")
    }

    private var glyph: String {
        if isRecording { return "circle.fill" }
        return makesTextSection ? "text.cursor" : "plus"
    }

    private var tint: Color {
        if isRecording { return WW.ember }
        return makesTextSection ? WW.moss : WW.inkTertiary
    }

    private var rule: some View {
        Rectangle().fill(WW.hairline).frame(height: 1).frame(maxWidth: .infinity)
    }
}

// MARK: - Text editor sheet

/// A full-screen text editor for a whole document — from the Documents list, or the document
/// screen's own "Edit" action — with find/replace along the bottom.
///
/// Editing a single block (an Inbox entry's transcript, one paragraph of a document) doesn't come
/// here any more: those are edited in place, in the list, by `InlineTextEditor`.
struct TextEditorSheet: View {
    let title: String
    @Binding var text: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showingFindReplace = false
    #if canImport(UIKit)
    @StateObject private var find = FindReplaceController()
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if canImport(UIKit)
                FindReplaceTextView(text: $text, controller: find)
                    .padding(8)
                if showingFindReplace {
                    FindReplaceBar(controller: find, text: $text) {
                        withAnimation { showingFindReplace = false }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                #else
                TextEditor(text: $text)
                    .padding()
                #endif
            }
            .background(WW.paper)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                #if canImport(UIKit)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showingFindReplace.toggle() }
                    } label: {
                        Image(systemName: showingFindReplace ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    }
                    .accessibilityLabel("Find and Replace")
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(); dismiss() }
                }
            }
        }
    }
}

// MARK: - Capture bar (record button + Auto transform)

/// The furniture along the bottom of the Inbox and of a document: the red record button, centered
/// just above the bar, and the "Auto transform" toggle below it.
///
/// Flipping the toggle on opens the list of transforms; picking one closes the list again and the
/// bar carries its name from then on (tap it to change your mind). The choice is remembered per
/// document — the Inbox and each document keep their own — and is applied by `AppModel` the first
/// time a clip filed there is transcribed.
struct CaptureBar: View {
    let presets: [PromptPreset]
    let selected: PromptPreset?
    let onSelect: (PromptPreset?) -> Void
    let onRecord: () -> Void

    /// Whether the Auto transform strip rides along underneath. It doesn't in one place: a document
    /// that's half of a joint document on a *phone*, where two panes share the height and a strip
    /// pinned to the bottom of each is more furniture than screen. There it goes into the list
    /// instead, under the document's own actions, where it scrolls away with everything else.
    var showsAutoTransform = true

    var body: some View {
        VStack(spacing: 0) {
            // No background behind the dot — the list's text passes underneath it. The padding is
            // lopsided on purpose: it lifts the dot clear of the bar without changing the height
            // this inset takes from the list.
            WWRecordButton(action: onRecord)
                .padding(.bottom, showsAutoTransform ? 20 : 12)

            if showsAutoTransform {
                AutoTransformBar(presets: presets, selected: selected, onSelect: onSelect)
            }
        }
    }
}

/// The "Auto transform" strip: the toggle, the transform it's set to, and the list to change it.
///
/// Its own view because it has two homes — pinned under the record button at the bottom of the
/// Inbox and of a document, and (on a phone, in half of a joint document) sitting in the list
/// itself, under the document's actions. Same control, same state, either way up.
struct AutoTransformBar: View {
    let presets: [PromptPreset]
    let selected: PromptPreset?
    let onSelect: (PromptPreset?) -> Void

    /// Whether the toggle reads as on. Held locally as well as in the store because "on, but no
    /// transform picked yet" is a real state: it's what you see between flipping the switch and
    /// choosing from the list.
    @State private var isOn = false
    @State private var showingList = false

    var body: some View {
        // The strip runs the full width; what's written on it is held to the content column, so
        // an iPad doesn't put the label and its switch a hand-span apart.
        VStack(spacing: 0) {
            WWHairline()
            if isOn && showingList {
                presetList.wwContentWidth()
                WWHairline()
            }
            toggleRow.wwContentWidth()
        }
        .background(WW.surface)
        .onAppear {
            isOn = selected != nil
            showingList = false
        }
        // A transform deleted (or reset) out from under the choice turns the toggle back off, rather
        // than leaving it reading "on" over nothing.
        .onChange(of: selected?.id) { _, id in
            if id == nil && !showingList { isOn = false }
        }
    }

    private var toggleRow: some View {
        HStack(spacing: 12) {
            Button {
                guard isOn else { return }
                withAnimation(.snappy(duration: 0.22)) { showingList.toggle() }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto transform")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(WW.ink)
                        if isOn {
                            Text(selected?.name ?? "Choose a transform")
                                .font(.caption)
                                .foregroundStyle(selected == nil ? WW.amber : WW.inkSecondary)
                        }
                    }
                    if isOn {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(showingList ? 0 : -90))
                            .foregroundStyle(WW.inkTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("Auto transform", isOn: Binding(get: { isOn }, set: { setOn($0) }))
                .labelsHidden()
                .tint(WW.moss)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// The transforms to choose from, with a checkmark against the active one. Bounded and
    /// scrollable so a long preset list can't swallow the screen.
    private var presetList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(presets) { preset in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            onSelect(preset)
                            showingList = false
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(preset.name)
                                .foregroundStyle(WW.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if preset.id == selected?.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(WW.moss)
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if preset.id != presets.last?.id { WWHairline().padding(.leading, 20) }
                }
            }
        }
        .frame(maxHeight: 190)
    }

    /// Flip the toggle: on opens the list to choose from (nothing runs until something is picked),
    /// off clears the stored choice.
    private func setOn(_ on: Bool) {
        withAnimation(.snappy(duration: 0.22)) {
            isOn = on
            showingList = on
            if !on { onSelect(nil) }
        }
    }
}

// MARK: - Inline text editor

/// The editor used for **in-line** editing: an Inbox entry's transcript, or one paragraph of a
/// document, edited where it sits in the list rather than in a sheet over it.
///
/// It grows to fit its text (the enclosing List scrolls, not the editor), takes the keyboard as soon
/// as it appears, tracks the caret so "Insert" can splice a fresh recording's transcript in at the
/// cursor, and sets the text in exactly the type it was already in — tapping to edit shouldn't
/// resize a word of it.
struct InlineTextEditor: View {
    @Binding var text: String
    @Binding var selection: NSRange
    /// The type this text is drawn in when it *isn't* being edited.
    let style: InlineTextStyle
    /// The heading the text opens with, if it opens with one — a graph node's `#` or `##`. Passed
    /// in so the editor is set in the same type the card was: tapping a heading to edit it shouldn't
    /// shrink it, and typing a `#` in front of a node should show you what you've just made. (Read
    /// from the live buffer by the caller, so it follows what's being typed.)
    var heading: GraphHeading? = nil
    /// What **Return** does, where Return is worth something other than a line break — a graph
    /// node, where it's the Done button said with the keyboard. Nil leaves Return alone, which is
    /// what a paragraph and an Inbox entry want: a blank line there splits the block in two.
    var onSubmit: (() -> Void)? = nil
    /// The size that text is set in (Settings → Display), so the editor opens at exactly the size
    /// the block was being read at.
    @Environment(\.transcriptTextSize) private var points: Double

    var body: some View {
        #if canImport(UIKit)
        InlineUITextEditor(text: $text, selection: $selection, style: style, points: points,
                           heading: heading, onSubmit: onSubmit)
        #else
        TextEditor(text: $text).font(style.font(points)).frame(minHeight: 120)
        #endif
    }
}

/// Where a piece of in-line editable text lives, and so how it's set. Each case pairs the SwiftUI
/// type the row draws with the UIKit type the editor uses, which is the whole point: they have to
/// match, or the text jumps size the moment you tap it.
///
/// The size itself is the user's (Settings → Display), handed in as points; each case says how it
/// reads that number and what line spacing goes with it.
enum InlineTextStyle {
    /// A paragraph of a document body: the chosen size, at `.lineSpacing(5)`.
    case documentBody
    /// An Inbox entry's transcript: the chosen size too — an Inbox entry is text you read, the same
    /// as a paragraph, so it's set the same. Only the line spacing is tighter, the rows being a
    /// feed rather than a page.
    case inboxTranscript
    /// A node on a graph canvas: two points under the chosen size, as it has always been. A node is
    /// a card pinned to fixed coordinates rather than a line of running text — its size decides how
    /// much of the canvas it covers — so it stays compact.
    case graphNode

    /// The size this style comes out at, given the text size chosen in Settings → Display. A
    /// paragraph and an Inbox entry are both set at the chosen size itself — one setting, one size,
    /// wherever text is read top-to-bottom. A node card keeps its two-point step below that.
    func pointSize(_ points: Double) -> CGFloat {
        switch self {
        case .documentBody, .inboxTranscript:   return CGFloat(points)
        case .graphNode:                        return CGFloat(max(points - 2, 9))
        }
    }

    /// What the row uses to draw the text.
    func font(_ points: Double) -> Font {
        .system(size: pointSize(points))
    }

    #if canImport(UIKit)
    /// The same type, as UIKit sees it — a fixed point size rather than a preferred text style,
    /// because the size is the user's own choice here (Settings → Display) rather than the system's,
    /// and the editor has to match the row it opened out of exactly.
    func uiFont(_ points: Double) -> UIFont {
        .systemFont(ofSize: pointSize(points))
    }

    var lineSpacing: CGFloat {
        switch self {
        case .documentBody:                 return 5
        case .inboxTranscript, .graphNode:  return 0
        }
    }
    #endif
}

#if canImport(UIKit)
/// A `UITextView` wrapper that sizes itself to its content and surfaces the caret/selection.
/// Scrolling is off, so `sizeThatFits` reports the full text height and the row grows with what you
/// type; two-way bindings keep `text` and `selection` in step with the view.
struct InlineUITextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let style: InlineTextStyle
    /// The chosen transcription text size, in points — passed in rather than read here so it's part
    /// of the value SwiftUI compares when deciding to update the view.
    var points: Double = AppSettings.defaultTranscriptTextSize
    /// A graph node's heading marker, when the text opens with one — see `InlineTextEditor`.
    var heading: GraphHeading? = nil
    /// What Return means here, when it means something other than a line break — see
    /// `InlineTextEditor.onSubmit` and `Coordinator.textView(_:shouldChangeTextIn:replacementText:)`.
    var onSubmit: (() -> Void)? = nil

    /// The one type this editor draws in: the style's own, or a heading's bold step up from it.
    private var uiFont: UIFont {
        guard let heading else { return style.uiFont(points) }
        return .boldSystemFont(ofSize: style.pointSize(points) + CGFloat(heading.extraPoints))
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false                       // grow instead; the List does the scrolling
        view.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        // Font, line spacing and ink all match the row this text was just being read in, so opening
        // the editor doesn't resize or recolor a word of it. Three places, because they cover
        // different moments: `font`/`textColor` for an empty editor (an attributed string with no
        // characters carries no attributes), the attributed text for what's already there, and the
        // typing attributes — set last, since assigning text rewrites them — for what's typed next.
        view.font = uiFont
        view.textColor = UIColor(WW.ink)
        view.attributedText = NSAttributedString(string: text, attributes: attributes)
        view.typingAttributes = attributes
        view.selectedRange = clamp(selection, to: text as NSString)
        // Where Return commits, the on-screen keyboard's return key says **Done** — the same word
        // as the button in the edit box's action row, which is the same thing it does.
        if onSubmit != nil { view.returnKeyType = .done }
        // Focus on the next runloop pass: the view isn't in the window hierarchy yet during make.
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // The coordinator answers UIKit out of whatever it was handed at make-time; hand it this
        // pass's view so the callbacks (Return most of all) are the ones the caller means now.
        context.coordinator.parent = self
        // The size can change under an open editor (Settings → Display, on another screen), so the
        // font is re-applied whenever it no longer matches rather than only at make-time.
        if uiView.text != text || uiView.font != uiFont {
            uiView.font = uiFont
            uiView.attributedText = NSAttributedString(string: text, attributes: attributes)
            uiView.typingAttributes = attributes           // replacing the text clears these
        }
        let clamped = clamp(selection, to: uiView.text as NSString)
        if uiView.selectedRange != clamped { uiView.selectedRange = clamped }
    }

    /// The one set of text attributes this editor draws with — see `InlineTextStyle`.
    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        return [.font: uiFont,
                .paragraphStyle: paragraph,
                .foregroundColor: UIColor(WW.ink)]
    }

    /// Report the height the text actually needs at the offered width, so the row is exactly as tall
    /// as what's in it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < .greatestFiniteMagnitude else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, 32))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func clamp(_ range: NSRange, to text: NSString) -> NSRange {
        let loc = max(0, min(range.location, text.length))
        let len = max(0, min(range.length, text.length - loc))
        return NSRange(location: loc, length: len)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InlineUITextEditor
        init(_ parent: InlineUITextEditor) { self.parent = parent }

        /// **Return commits**, where the editor has said what committing means (a graph node: the
        /// same thing its **Done** does). **Shift + Return** still puts a line break in, for the
        /// times a card really does want two lines.
        ///
        /// Shift is read off `ModifierKeyMonitor` rather than the text view, which is handed the
        /// same "\n" either way and can't tell you which one you pressed. With no hardware
        /// keyboard nothing reports shift, so Return simply commits — which is why the soft
        /// keyboard's return key is relabelled **Done** to say so before it's pressed.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            guard let onSubmit = parent.onSubmit, text == "\n",
                  !ModifierKeyMonitor.shared.isShiftDown else { return true }
            // Out of the delegate callback first: committing tears this view down, and doing that
            // while UIKit is still asking it about an edit is asking for trouble.
            DispatchQueue.main.async { onSubmit() }
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.selection = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selection = textView.selectedRange
        }
    }
}
#endif

// MARK: - Find & Replace

#if canImport(UIKit)
/// Drives the find/replace bar. Holds the search/replace terms and a weak handle to the editor's
/// `UITextView`, and runs the actual find/replace operations against it — selecting and scrolling to
/// matches (so they highlight) and pushing edited text back through the `onChange` callback.
@MainActor
final class FindReplaceController: ObservableObject {
    @Published var find = ""
    @Published var replace = ""

    weak var textView: UITextView?

    private let options: NSString.CompareOptions = [.caseInsensitive]

    /// Number of (case-insensitive) matches of `find` in `text`, for the "n" match counter.
    func matchCount(in text: String) -> Int {
        guard !find.isEmpty else { return 0 }
        let ns = text as NSString
        var count = 0
        var searchStart = 0
        while searchStart < ns.length {
            let range = ns.range(of: find, options: options,
                                 range: NSRange(location: searchStart, length: ns.length - searchStart))
            if range.location == NSNotFound { break }
            count += 1
            searchStart = range.location + max(range.length, 1)
        }
        return count
    }

    /// Select the next match after the current selection, wrapping around to the top.
    func findNext() {
        guard let tv = textView, !find.isEmpty else { return }
        let ns = tv.text as NSString
        let from = min(tv.selectedRange.location + tv.selectedRange.length, ns.length)
        var range = ns.range(of: find, options: options,
                             range: NSRange(location: from, length: ns.length - from))
        if range.location == NSNotFound {
            range = ns.range(of: find, options: options, range: NSRange(location: 0, length: ns.length))
        }
        select(range, in: tv)
    }

    /// Select the previous match before the current selection, wrapping around to the bottom.
    func findPrevious() {
        guard let tv = textView, !find.isEmpty else { return }
        let ns = tv.text as NSString
        let end = max(tv.selectedRange.location, 0)
        var range = ns.range(of: find, options: options.union(.backwards),
                             range: NSRange(location: 0, length: end))
        if range.location == NSNotFound {
            range = ns.range(of: find, options: options.union(.backwards),
                             range: NSRange(location: 0, length: ns.length))
        }
        select(range, in: tv)
    }

    /// Replace the current match (if the selection is one) and advance to the next; otherwise just
    /// move to the next match.
    func replaceCurrent(_ onChange: (String) -> Void) {
        guard let tv = textView, !find.isEmpty else { return }
        let ns = tv.text as NSString
        let sel = tv.selectedRange
        if sel.length > 0, ns.substring(with: sel).compare(find, options: options) == .orderedSame {
            let updated = ns.replacingCharacters(in: sel, with: replace)
            tv.text = updated
            onChange(updated)
            tv.selectedRange = NSRange(location: sel.location + (replace as NSString).length, length: 0)
        }
        findNext()
    }

    /// Replace every match of `find` with `replace`.
    func replaceAll(_ onChange: (String) -> Void) {
        guard let tv = textView, !find.isEmpty else { return }
        let ns = tv.text as NSString
        let updated = ns.replacingOccurrences(of: find, with: replace, options: options,
                                              range: NSRange(location: 0, length: ns.length))
        guard updated != tv.text else { return }
        tv.text = updated
        onChange(updated)
        tv.selectedRange = NSRange(location: 0, length: 0)
    }

    private func select(_ range: NSRange, in tv: UITextView) {
        guard range.location != NSNotFound else { return }
        tv.becomeFirstResponder()
        tv.selectedRange = range
        tv.scrollRangeToVisible(range)
    }
}

/// A `UITextView`-backed editor that hands the controller a reference to its text view so find/
/// replace can select and scroll to matches (a plain SwiftUI `TextEditor` exposes neither).
struct FindReplaceTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: FindReplaceController
    /// The document's own text size, so the whole-document editor reads like the page it came from.
    @Environment(\.transcriptTextSize) private var transcriptTextSize: Double

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = InlineTextStyle.documentBody.uiFont(transcriptTextSize)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.text = text
        controller.textView = view
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        let font = InlineTextStyle.documentBody.uiFont(transcriptTextSize)
        if uiView.font != font { uiView.font = font }
        controller.textView = uiView
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: FindReplaceTextView
        init(_ parent: FindReplaceTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

/// The find/replace bar pinned below the editor: a Find row (with match count + prev/next) and a
/// Replace row (with Replace / Replace All).
private struct FindReplaceBar: View {
    @ObservedObject var controller: FindReplaceController
    @Binding var text: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(WW.inkTertiary)
                TextField("Find", text: $controller.find)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !controller.find.isEmpty {
                    Text("\(controller.matchCount(in: text))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WW.inkSecondary)
                }
                Button { controller.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .disabled(controller.find.isEmpty)
                Button { controller.findNext() } label: { Image(systemName: "chevron.down") }
                    .disabled(controller.find.isEmpty)
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(WW.inkTertiary)
                }
                .accessibilityLabel("Close Find")
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.2.squarepath").foregroundStyle(WW.inkTertiary)
                TextField("Replace", text: $controller.replace)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Replace") { controller.replaceCurrent { text = $0 } }
                    .disabled(controller.find.isEmpty)
                Button("All") { controller.replaceAll { text = $0 } }
                    .disabled(controller.find.isEmpty)
            }
        }
        .textFieldStyle(.plain)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WW.surface)
        .overlay(alignment: .top) { WWHairline() }
    }
}
#endif

// MARK: - Share

/// Wraps a piece of text so it can drive a `.sheet(item:)` share presentation.
struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

/// Wraps an audio file URL so it can drive a `.sheet(item:)` share presentation (share the clip).
struct AudioShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Wraps an exported `.wwdoc` file URL so it can drive a `.sheet(item:)` share presentation
/// (share the whole document — audio + edited transcriptions — as one file).
struct DocumentFileShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
/// Bridges `UIActivityViewController` for share sheets — shares text or a file URL.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Recording row

/// A compact recordings-list row: play control + single-line transcript. Reorder, delete, and
/// re-record/move are driven by the enclosing List (long-press + swipes).
private struct RecordingRow: View {
    let recording: Recording
    let isActive: Bool
    let isPaused: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // An entry imported as text (moved here from the Inbox) has no clip to play; a text
            // glyph stands in its place so the row still lines up with its neighbours.
            if recording.isTextOnly {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WW.inkTertiary)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
            } else {
                PlayControl(isPlaying: isActive && !isPaused, action: onPlay)
            }

            RecordingLabel(recording: recording)

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

/// A small hairline-ringed circular play/pause control used by every recordings list.
struct PlayControl: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WW.moss)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A transcript summary for a recording, truncated to `lineLimit` lines (1 for the compact
/// document list, more for the Inbox preview), or a status placeholder while not yet done.
private struct RecordingLabel: View {
    let recording: Recording
    /// How many lines of transcript to show — nil for all of them (an Inbox entry tapped open).
    var lineLimit: Int? = 1
    @Environment(\.transcriptTextSize) private var transcriptTextSize: Double

    var body: some View {
        switch recording.status {
        case .done:
            Text(text)
                .font(InlineTextStyle.inboxTranscript.font(transcriptTextSize))
                .foregroundStyle(WW.ink)
                .lineLimit(lineLimit)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Transcribing…").font(.subheadline).foregroundStyle(WW.inkSecondary).lineLimit(1)
            }
        case .pending:
            Text("Waiting to transcribe").font(.subheadline).foregroundStyle(WW.inkSecondary).lineLimit(1)
        case .failed:
            Text("Transcription failed").font(.subheadline).foregroundStyle(WW.amber).lineLimit(1)
        }
    }

    private var text: String {
        let t = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "(no speech detected)" : t
    }
}

// MARK: - Playback

/// Plays a single recording at a time with real transport state: progress, elapsed/duration, and
/// pause/resume. Crucially it puts the audio session into `.playback` first — without that the
/// session can be left in a record-oriented or muted-ambient mode, so `AVAudioPlayer.play()`
/// returns but routes to the receiver or stays silent (the "nothing happens" symptom). Lives in
/// this file so the app target picks it up without an xcodegen regen.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var playingID: UUID?
    @Published private(set) var isPaused = false
    @Published private(set) var progress: Double = 0          // 0...1
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    /// Surfaces a user-facing error message (e.g. a missing/unreadable audio file).
    var onError: ((String) -> Void)?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Tapping the active recording pauses/resumes it; tapping another switches to it.
    func toggle(_ recording: Recording, url: URL) {
        if playingID == recording.id {
            isPaused ? resume() : pause()
        } else {
            start(id: recording.id, url: url)
        }
    }

    private func start(id: UUID, url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            onError?("Couldn't play audio: the recording file is missing.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else {
                onError?("Couldn't start audio playback.")
                return
            }
            player = p
            playingID = id
            isPaused = false
            duration = p.duration
            currentTime = 0
            progress = 0
            startTimer()
        } catch {
            onError?("Couldn't play audio: \(error.localizedDescription)")
        }
    }

    func pause() {
        player?.pause()
        isPaused = true
        stopTimer()
    }

    func resume() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPaused = false
        startTimer()
    }

    func stop() {
        stopTimer()
        player?.stop()
        player = nil
        playingID = nil
        isPaused = false
        progress = 0
        currentTime = 0
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        duration = player.duration
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Recording sheet

/// A compact bottom "toast" recording surface: it starts recording the moment it appears, shows an
/// elapsed-time counter and a live gain meter, and offers three equal-size controls — cancel, save,
/// and pause/continue. Save hands the finished clip back via `onComplete`; swiping the sheet down
/// discards the clip. Lives here (not a standalone file) so the app target picks it up without an
/// xcodegen regen.
///
/// The same three controls are mirrored onto the Lock Screen and the Dynamic Island for as long as
/// the recording runs: this sheet raises a Live Activity when capture starts, keeps its paused state
/// current, and takes it down when the recording ends. While it's up, this sheet holds the
/// `RecordingRemote` controls, so a press over there runs against this very recorder — there's one
/// recording either way, not a copy of one.
struct RecordingSheet: View {
    let title: String
    /// Supplies a fresh URL to record into (e.g. `store.newAudioURL().url`).
    let makeURL: () -> URL
    /// Called with the finished file and its duration when the user taps stop.
    let onComplete: (URL, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var live = LiveTranscriber()
    @AppStorage("showLiveTranscription") private var showLiveTranscription = false
    @State private var startedURL: URL?
    @State private var didComplete = false
    @State private var errorMessage: String?
    @State private var showingCancelConfirm = false

    /// Whether the live-transcription panel is shown for this recording: the setting is on and the
    /// speech model is loaded (nothing to transcribe against otherwise).
    private var liveEnabled: Bool { showLiveTranscription && model.transcriptionReady }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 16) {
                if liveEnabled {
                    // Size the live box to ~75% of the sheet height (the sheet uses the .large detent
                    // when live transcription is on, so this is ~75% of the window).
                    livePanel(boxHeight: geo.size.height * 0.75)
                }

                Text(timeString(recorder.elapsed))
                    .font(.system(size: 36, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(recorder.isPaused ? WW.inkTertiary : WW.ink)

                LevelMeter(level: recorder.currentLevel)
                    .tint(WW.ember)

                HStack(spacing: 28) {
                    Button { showingCancelConfirm = true } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(WWRoundIconButtonStyle(diameter: 52, glyphColor: WW.inkSecondary))
                    .accessibilityLabel("Cancel")

                    Button { finish() } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(WWRoundIconButtonStyle(diameter: 62, fill: WW.ember))
                    .accessibilityLabel("Save")

                    Button { setPaused(!recorder.isPaused) } label: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(WWRoundIconButtonStyle(diameter: 52, glyphColor: WW.ink))
                    .disabled(!recorder.isRecording)
                    .accessibilityLabel(recorder.isPaused ? "Continue" : "Pause")
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: liveEnabled ? .top : .center)
        }
        .presentationBackground(WW.surface)
        .presentationDetents([liveEnabled ? .large : .height(230)])
        .interactiveDismissDisabled(true)
        .task { await begin() }
        .onDisappear { discardIfUnfinished() }
        .confirmationDialog("Discard this recording?", isPresented: $showingCancelConfirm,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancel() }
            Button("Keep Recording", role: .cancel) { }
        }
        .alert("Couldn't record", isPresented: Binding(get: { errorMessage != nil },
                                                       set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { dismiss() }
        } message: { Text(errorMessage ?? "") }
    }

    /// Scrolling live transcript of the clip-so-far, shown above the record controls when the
    /// setting is on. Re-transcribed roughly once a second by `LiveTranscriber`. `boxHeight` sizes
    /// the scroll area (≈75% of the sheet).
    private func livePanel(boxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WW.inkSecondary)
                Text("Live Transcription")
                    .font(WW.sectionLabel)
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(WW.inkSecondary)
                if live.isProcessing { ProgressView().controlSize(.mini) }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(live.text.isEmpty ? "Listening…" : live.text)
                        .font(.system(size: 19))
                        .lineSpacing(5)
                        .foregroundStyle(live.text.isEmpty ? WW.inkTertiary : WW.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("liveTextEnd")
                }
                .onChange(of: live.text) { _, _ in
                    withAnimation { proxy.scrollTo("liveTextEnd", anchor: .bottom) }
                }
            }
            .frame(height: boxHeight)
        }
        .padding(12)
        .background(WW.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(WW.hairline, lineWidth: 1))
    }

    /// Discard the in-progress clip and close.
    private func cancel() {
        live.stop()
        discardIfUnfinished()
        dismiss()
    }

    /// Auto-start recording as soon as the toast appears.
    private func begin() async {
        guard startedURL == nil else { return }
        guard await recorder.requestPermission() else {
            errorMessage = "Microphone permission is required to record."
            return
        }
        let url = makeURL()
        do {
            try recorder.start(to: url)
            startedURL = url
            WWHaptics.recordingStarted()
            // Mirror the recorder onto the Lock Screen / Dynamic Island for as long as it runs, and
            // take the controls over there, so a press lands on this recording.
            RecordingActivityController.shared.start(taskName: title)
            RecordingRemote.shared.takeControl(handle)
            // Live transcription runs a second, in-memory capture alongside the recorder.
            if liveEnabled { live.start(using: model.transcription) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        live.stop()
        endLockScreenPresence()
        guard let result = recorder.stop() else { dismiss(); return }
        didComplete = true
        onComplete(result.url, result.duration)
        dismiss()
    }

    /// Swiped away without stopping: drop the in-progress clip. Also the last stop on every other
    /// exit (`finish` dismisses into it), so it's where the Lock Screen presence is guaranteed to
    /// come down — taking it down twice is a no-op.
    private func discardIfUnfinished() {
        live.stop()
        endLockScreenPresence()
        guard !didComplete else { return }
        _ = recorder.stop()
        if let url = startedURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Take the Live Activity down and hand back the remote controls, so a press on an activity the
    /// system hasn't cleared yet can't reach a recorder that's already finished.
    private func endLockScreenPresence() {
        RecordingActivityController.shared.end()
        RecordingRemote.shared.releaseControl()
    }

    /// Pause or continue, from either the on-screen button or the Lock Screen, keeping the live
    /// transcriber and the Live Activity in step with the recorder.
    private func setPaused(_ paused: Bool) {
        guard recorder.isRecording, recorder.isPaused != paused else { return }
        if paused { recorder.pause() } else { recorder.resume() }
        live.setPaused(paused)
        RecordingActivityController.shared.update(isPaused: recorder.isPaused,
                                                  elapsed: recorder.elapsed)
    }

    /// Act on a control pressed on the Lock Screen or in the Dynamic Island. Registered with
    /// `RecordingRemote` while this recording runs, so the press is handled against the recorder
    /// that's actually capturing rather than a copy of its state.
    ///
    /// The same actions the sheet itself offers, with one difference: Discard skips the
    /// confirmation dialog, because a locked screen is nowhere to put one. Its button over there is
    /// the quietest of the three for that reason.
    private func handle(_ action: RecordingRemote.Action) {
        switch action {
        case .pause:   setPaused(true)
        case .resume:  setPaused(false)
        case .save:    finish()
        case .discard: cancel()
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Inbox

/// The Inbox: a flat list of recordings (Watch clips and "New Recording" captures), not a
/// document. Newest capture first. Tapping a row opens its transcript for editing **in place** —
/// the entry grows into an outlined editor with its actions in the bar below — while swipe left
/// gives Move / Delete and swipe right Copy / Transform. Lives here so the app target picks it up
/// without an xcodegen regen.
struct InboxView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    @State private var showingRecorder = false

    // In-place transcript editing: the open entry, its live buffer and caret, and whether a
    // transform/reset is currently running against it.
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var editingSelection = NSRange(location: 0, length: 0)
    @State private var isWorking = false

    // The open editor's Transform picker and its Share (text or audio?) choice.
    @State private var showingEditorTransform = false
    @State private var showingShareChoice = false
    @State private var shareTarget: ShareTarget?

    // "Import Text File…" from the toolbar menu
    @State private var showingTextImporter = false

    // Long-press-to-select (the Inbox's own batch mode).
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []

    // Entries showing every line of their transcript rather than the first few — a single tap
    // opens one up, another closes it again. Editing is the *double* tap, so reading a long capture
    // no longer means opening an editor over it.
    @State private var expandedIDs: Set<UUID> = []

    // Move-to-document pane: the recordings being moved (one, from a swipe; or many, from batch).
    @State private var movingIDs: Set<UUID>?

    // Swipe-right Transform: which recording is picking a preset, and which are mid-transform
    // (their rows show a spinner in place of the transcript preview).
    @State private var transformTargetID: UUID?
    @State private var transformingIDs: Set<UUID> = []

    // New-document step: the recordings to drop into a fresh doc, plus its editable title.
    @State private var pendingNewDocIDs: Set<UUID>?
    @State private var newDocTitle = ""

    // Tags: the entries a tag is being picked for, and the one the list is filtered by.
    @State private var taggingIDs: Set<UUID>?
    @State private var filterTag: String?
    @State private var showingFilteredDeleteConfirm = false

    private var inbox: Document? { model.documents.document(with: documentID) }
    /// Newest first — the Inbox reads as a capture feed, so the clip you just made is at the top.
    private var recordings: [Recording] {
        (inbox?.recordings ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    private var documentTargets: [Document] {
        model.documents.documents.filter { $0.id != documentID && $0.title != DocumentStore.inboxTitle }
    }

    /// The tags on offer, as Settings has them — name and colour both.
    private var tags: [InboxTagStyle] { AppSettings.shared.inboxTags }

    /// The ink a tag is drawn in. A tag an entry still carries after it's been dropped from
    /// Settings has no colour of its own left, so it falls back to the app's accent — it keeps its
    /// filter, it just stops being colour-coded.
    private func tagColor(_ name: String?) -> Color {
        WW.tagColor(tags.first { $0.name == name }?.colorID)
    }

    /// The tags worth filtering by: the ones entries are actually filed under, in the order Settings
    /// lists them — followed by any an entry still carries that the list has since dropped, since
    /// those entries are exactly the ones you'd want a way back to.
    private var tagsInUse: [String] {
        let used = Set(recordings.compactMap(\.tag))
        let configured = tags.map(\.name)
        return configured.filter(used.contains) + used.subtracting(configured).sorted()
    }

    /// What the list is showing: everything, or one tag's worth. A filter on a tag that has just
    /// lost its last entry falls away on its own rather than leaving an empty screen.
    private var visibleRecordings: [Recording] {
        guard let filterTag else { return recordings }
        return recordings.filter { $0.tag == filterTag }
    }

    var body: some View {
        List {
            ForEach(visibleRecordings) { recording in
                inboxRow(recording)
            }
        }
        .wwList()
        // The filter row rides above the list rather than scrolling with it: it's how you're
        // *reading* the Inbox, so it stays put while the entries move under it.
        .safeAreaInset(edge: .top, spacing: 0) { tagFilterBar() }
        .onChange(of: tagsInUse) { _, inUse in
            // The last entry under this tag has just gone (deleted, moved, re-filed): drop the
            // filter rather than leaving an empty list with no way to see it's a filter's doing.
            if let filterTag, !inUse.contains(filterTag) { self.filterTag = nil }
        }
        .navigationTitle(selectionMode ? "\(selected.count) selected" : DocumentStore.inboxTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectionMode {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { exitSelection() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected.count == visibleRecordings.count ? "Deselect All" : "Select All") {
                        selectAll()
                    }
                }
            } else {
                // The import menu the documents carry. (No mic beside it any more — recording is the
                // red button above the bottom bar.) The Inbox takes text you already have as readily
                // as it takes something you said.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        TextImportItems(onClipboard: importFromClipboard,
                                        onFile: { showingTextImporter = true })
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Import Text")
                }
            }
        }
        .fileImporter(isPresented: $showingTextImporter,
                      allowedContentTypes: TextImportItems.contentTypes,
                      onCompletion: importTextFile)
        // The bottom strip: the batch bar while selecting, otherwise the record button over the
        // Auto transform toggle. With an entry open for editing it stands down — those actions ride
        // inside the edit box, against the text they apply to.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectionMode {
                WWBatchBar {
                    WWBatchButton("Delete", "trash", role: .destructive) {
                        model.documents.deleteRecordings(selected, fromDocument: documentID)
                        exitSelection()
                    }
                    WWBatchButton("Copy", "doc.on.doc") { copySelected() }
                    WWBatchButton("Tag", "tag") {
                        withAnimation(.snappy(duration: 0.22)) { taggingIDs = selected }
                    }
                    WWBatchButton("New", "doc.badge.plus") { startNewDocument(for: selected) }
                    WWBatchButton("Move", "folder") {
                        withAnimation(.snappy(duration: 0.22)) { movingIDs = selected }
                    }
                }
                .disabled(selected.isEmpty)
            } else if editingID == nil {
                VStack(spacing: 0) {
                    // While a filter is on, the whole of what's on screen is one kind of thing —
                    // so there's a sensible "all of it" to copy or to be rid of.
                    if filterTag != nil { filteredActionsBar() }
                    CaptureBar(presets: model.documents.presets,
                               selected: model.autoTransformPreset(for: documentID),
                               onSelect: { model.setAutoTransform($0, for: documentID) },
                               onRecord: { showingRecorder = true })
                }
            }
        }
        .overlay {
            if recordings.isEmpty {
                WWEmptyState(title: "Inbox is empty",
                             systemImage: "tray",
                             message: "Recordings from your Watch and the record button land here — as does text you import.")
            }
        }
        .sheet(isPresented: $showingRecorder) {
            RecordingSheet(title: "New Recording",
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                model.addDeviceRecording(audioURL: url, duration: duration, toDocument: documentID)
            }
        }
        // The open editor's Transform picker: runs against the text as it stands on screen.
        .confirmationDialog("Transform — \(AppSettings.shared.model.shortName)",
                            isPresented: $showingEditorTransform, titleVisibility: .visible) {
            ForEach(model.documents.presets) { preset in
                Button(preset.name) { transformEditing(preset) }
            }
        }
        // Share the words or the audio. "Text" is offered only once there's something to send.
        .confirmationDialog("Share", isPresented: $showingShareChoice, titleVisibility: .visible) {
            if !editingIsEmpty {
                Button("Text") { shareTarget = ShareTarget(items: [editingText]) }
            }
            Button("Audio Recording") { shareEditingAudio() }
        }
        .sheet(item: $shareTarget) { target in
            ActivityView(activityItems: target.items)
        }
        .overlay {
            if let ids = movingIDs {
                moveOverlay(ids: ids)
            }
        }
        .overlay {
            if let ids = taggingIDs {
                tagOverlay(ids: ids)
            }
        }
        .confirmationDialog("Delete every “\(filterTag ?? "")” entry?",
                            isPresented: $showingFilteredDeleteConfirm, titleVisibility: .visible) {
            Button("Delete \(visibleRecordings.count)", role: .destructive) { deleteFiltered() }
        } message: {
            Text("The audio goes with them. This can't be undone.")
        }
        // Swipe-right Transform: pick the preset, then rewrite the transcript in place. The target
        // id is captured while the dialog is built, so the action doesn't race the dismissal.
        .confirmationDialog("Transform — \(AppSettings.shared.model.shortName)",
                            isPresented: Binding(get: { transformTargetID != nil },
                                                 set: { if !$0 { transformTargetID = nil } }),
                            titleVisibility: .visible) {
            if let id = transformTargetID {
                ForEach(model.documents.presets) { preset in
                    Button(preset.name) { transform(preset, recordingID: id) }
                }
            }
        }
        .alert("Rename document",
               isPresented: Binding(get: { pendingNewDocIDs != nil },
                                    set: { if !$0 { pendingNewDocIDs = nil } })) {
            TextField("Title", text: $newDocTitle)
            Button("Save") { confirmNewDocument() }
            Button("Cancel", role: .cancel) { pendingNewDocIDs = nil }
        }
    }

    // MARK: Rows

    /// One Inbox entry. The entry being edited keeps its gestures to itself — a tap, a long press
    /// and a swipe all belong to the text view (caret, selection handles) rather than to selection
    /// mode, Move, or Delete.
    @ViewBuilder
    private func inboxRow(_ recording: Recording) -> some View {
        let isEditing = editingID == recording.id
        let row = InboxRecordingRow(
            recording: recording,
            selectionMode: selectionMode,
            isSelected: selected.contains(recording.id),
            // Either kind of rewrite reads the same from the row: one you asked for, or the
            // Auto transform running itself over a clip that has just been transcribed.
            isTransforming: transformingIDs.contains(recording.id)
                || model.autoTransformingIDs.contains(recording.id),
            isThinking: model.isThinking(recording.id),
            isEditing: isEditing,
            isExpanded: expandedIDs.contains(recording.id),
            onTapLabel: {
                if selectionMode { toggle(recording.id) } else { toggleExpanded(recording.id) }
            },
            onDoubleTapLabel: {
                if selectionMode { toggle(recording.id) } else { startEditing(recording) }
            },
            onLongPress: { enterSelection(with: recording.id) },
            onCopy: { copy(recording) },
            onRetranscribe: { Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) } },
            moveTargets: documentTargets,
            onMove: { target in model.documents.moveRecording(recording.id, from: documentID, to: target.id) },
            tagColor: tagColor(recording.tag)
        ) {
            if isEditing { transcriptEditBox() }
        }
        .wwRow()
        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))

        if isEditing {
            row
        } else {
            row
                // Swipe left → Move / Delete. No full swipe: both are consequential, and a stray
                // flick shouldn't bin a capture.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) {
                        model.documents.deleteRecording(recording.id, fromDocument: documentID)
                    }
                    .tint(WW.ember)
                    Button("Move") { withAnimation(.snappy(duration: 0.22)) { movingIDs = [recording.id] } }
                        .tint(WW.slate)
                }
                // Swipe right → Tag / Copy / Transform.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button("Tag") {
                        withAnimation(.snappy(duration: 0.22)) { taggingIDs = [recording.id] }
                    }.tint(WW.moss)
                    Button("Copy") { copy(recording) }.tint(WW.inkTertiary)
                    Button("Transform") { transformTargetID = recording.id }
                        .tint(WW.violet)
                        .disabled(!model.modelReady)
                }
        }
    }

    // MARK: In-place transcript editing

    /// The open entry's transcript inside its outline, with Copy / Share / Transform / Reset along
    /// the bottom of that same outline and Done at its right. Everything the sheet editor offered,
    /// minus the sheet.
    private func transcriptEditBox() -> some View {
        WWInlineEditBox(onDone: { finishEditing() }, isWorking: isWorking) {
            InlineTextEditor(text: $editingText, selection: $editingSelection,
                             style: .inboxTranscript)
        } actions: {
            WWInlineEditAction("Copy", "doc.on.doc", enabled: !isWorking && !editingIsEmpty) {
                copyEditing()
            }
            WWInlineEditAction("Share", "square.and.arrow.up",
                               enabled: !isWorking && !(editingIsTextOnly && editingIsEmpty)) {
                shareEditing()
            }
            WWInlineEditAction("Transform", "wand.and.stars",
                               enabled: model.modelReady && !isWorking && !editingIsEmpty) {
                persistEditing()
                showingEditorTransform = true
            }
            WWInlineEditAction("Reset", "arrow.uturn.backward",
                               enabled: !isWorking && !editingIsTextOnly) {
                resetEditing()
            }
        }
    }

    /// The entry currently open in the editor, read live so a transform or reset can be read back.
    private var editingRecording: Recording? { recordings.first { $0.id == editingID } }

    private var editingIsEmpty: Bool {
        editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An entry that came in as text has no audio to share and no original transcription to reset to.
    private var editingIsTextOnly: Bool { editingRecording?.isTextOnly ?? false }

    /// A single tap on an entry: show all of its transcript, or fold it back to a few lines. The
    /// row grows in place — nothing opens over it — so a long capture can simply be read.
    private func toggleExpanded(_ id: UUID) {
        withAnimation(.snappy(duration: 0.22)) {
            if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        }
    }

    /// Open an entry for editing, committing whatever was open before it. The caret starts at the
    /// end of the text.
    private func startEditing(_ recording: Recording) {
        if editingID != nil { finishEditing() }
        let text = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        editingText = text
        editingSelection = NSRange(location: (text as NSString).length, length: 0)
        isWorking = false
        withAnimation(.snappy(duration: 0.22)) { editingID = recording.id }
    }

    /// Write the buffer back onto the recording. Also run before Transform and Share, so those act
    /// on what's on screen rather than the last-saved transcript.
    private func persistEditing() {
        guard var recording = editingRecording else { return }
        let text = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recording.transcript != text else { return }
        recording.transcript = text
        model.documents.updateRecording(recording, inDocument: documentID)
    }

    /// Done: save and close the editor.
    private func finishEditing() {
        guard editingID != nil else { return }
        persistEditing()
        withAnimation(.snappy(duration: 0.22)) { editingID = nil }
    }

    private func copyEditing() {
        #if canImport(UIKit)
        UIPasteboard.general.string = editingText
        #endif
        wwLog("Copied transcript of “\(editingRecording?.name ?? "recording")”", .general)
    }

    /// Share the words or — when there's a clip behind the entry — offer the audio too.
    private func shareEditing() {
        persistEditing()
        if editingIsTextOnly { shareTarget = ShareTarget(items: [editingText]) }
        else { showingShareChoice = true }
    }

    /// Hand the clip's audio file to the share sheet, reporting the missing-file case rather than
    /// opening a share sheet on a URL that points at nothing.
    private func shareEditingAudio() {
        guard let recording = editingRecording else { return }
        let url = model.documents.audioURL(for: recording)
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.setupError = "Couldn't share the audio: the recording file is missing."
            return
        }
        shareTarget = ShareTarget(items: [url])
    }

    /// Run a preset over the open entry and re-seed the editor from the result.
    private func transformEditing(_ preset: PromptPreset) {
        guard let id = editingID else { return }
        isWorking = true
        Task {
            await model.transformRecordingTranscript(preset, recordingID: id, in: documentID)
            reseedEditor(from: id)
            isWorking = false
        }
    }

    /// Reset: re-run speech-to-text over the audio to restore the original transcription, discarding
    /// edits. (Not a first transcription, so an Auto transform stays out of it.)
    private func resetEditing() {
        guard let id = editingID else { return }
        isWorking = true
        Task {
            await model.transcribe(recordingID: id, inDocument: documentID)
            reseedEditor(from: id)
            isWorking = false
        }
    }

    /// Pull the stored transcript back into the editor after a transform or reset rewrote it.
    private func reseedEditor(from recordingID: UUID) {
        guard editingID == recordingID,
              let text = recordings.first(where: { $0.id == recordingID })?.transcript else { return }
        editingText = text
        editingSelection = NSRange(location: (text as NSString).length, length: 0)
    }

    // MARK: Importing text

    /// File the clipboard's text away as a new Inbox entry.
    private func importFromClipboard() {
        guard let text = model.clipboardText() else { return }
        model.importText(text, intoInbox: documentID)
    }

    /// File a picked text file's contents away as a new Inbox entry.
    private func importTextFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard let text = model.importedText(from: url) else { return }
            model.importText(text, intoInbox: documentID)
        case .failure(let error):
            model.setupError = "Couldn't open that file: \(error.localizedDescription)"
        }
    }

    /// Run a preset against one recording's transcript, marking its row busy while it works.
    private func transform(_ preset: PromptPreset, recordingID: UUID) {
        transformingIDs.insert(recordingID)
        Task {
            await model.transformRecordingTranscript(preset, recordingID: recordingID, in: documentID)
            transformingIDs.remove(recordingID)
        }
    }

    // MARK: Tags

    /// The row of tags across the top of the Inbox, there only once something is filed under one —
    /// a filter you didn't ask for is a control in the way, and an Inbox nobody has tagged has
    /// nothing to filter.
    ///
    /// Tapping the tag you're already on takes the filter off, which is the same gesture as tapping
    /// "All" and saves reaching for it.
    @ViewBuilder
    private func tagFilterBar() -> some View {
        let inUse = tagsInUse
        if !inUse.isEmpty, !selectionMode, editingID == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tagChip("All", isOn: filterTag == nil, tint: WW.inkSecondary) {
                        withAnimation(.snappy(duration: 0.2)) { filterTag = nil }
                    }
                    ForEach(inUse, id: \.self) { tag in
                        tagChip(tag, isOn: filterTag == tag, tint: tagColor(tag)) {
                            withAnimation(.snappy(duration: 0.2)) {
                                filterTag = (filterTag == tag) ? nil : tag
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .background(WW.paper)
            .overlay(alignment: .bottom) { WWHairline() }
        }
    }

    /// A filter chip in its tag's own colour: outlined in it while it's off, filled with it while
    /// it's on, so the row reads as a set of tags rather than a set of buttons.
    private func tagChip(_ title: String, isOn: Bool, tint: Color,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? WW.paper : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? tint : tint.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(isOn ? tint : tint.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// What a filtered Inbox can do to the whole of what it's showing: take it all, make a document
    /// of it, or be rid of it all. It only stands up while a filter is on, because "all of it" only
    /// means something when what's on screen is one kind of thing.
    ///
    /// **New Document** is the one that earns the filter: a tag is usually a pile that turns into
    /// something — every Question you had on the trail becomes the list you take to someone — and it
    /// goes through the same step a Move does, so the document is named, the entries move across
    /// with their audio, and the body is seeded with what they said.
    @ViewBuilder
    private func filteredActionsBar() -> some View {
        HStack(spacing: 0) {
            filteredAction("Copy All", "doc.on.doc", tint: WW.moss) { copyFiltered() }
            filteredAction("New Document", "doc.badge.plus", tint: WW.moss) {
                startNewDocument(for: Set(visibleRecordings.map(\.id)), titled: filterTag)
            }
            filteredAction("Delete All", "trash", tint: WW.ember) {
                showingFilteredDeleteConfirm = true
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: WW.contentMaxWidth)
        .frame(maxWidth: .infinity)
        // No plate and no rule: the two words float over the paper the entries scroll past on, the
        // way the record button does. They belong to the filter above them, not to the bar below.
        .disabled(visibleRecordings.isEmpty)
        .opacity(visibleRecordings.isEmpty ? 0.35 : 1)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func filteredAction(_ title: String, _ icon: String, tint: Color,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Every entry the filter is showing, as one piece of text — the same shape a batch Copy hands
    /// over, in the order they're on screen.
    private func copyFiltered() {
        let text = visibleRecordings
            .compactMap { $0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        WWHaptics.light()
        wwLog("Copied \(visibleRecordings.count) “\(filterTag ?? "")” entries", .general)
    }

    private func deleteFiltered() {
        let ids = Set(visibleRecordings.map(\.id))
        guard !ids.isEmpty else { return }
        model.documents.deleteRecordings(ids, fromDocument: documentID)
        wwLog("Deleted \(ids.count) “\(filterTag ?? "")” entries", .general)
        withAnimation(.snappy(duration: 0.2)) { filterTag = nil }
    }

    /// The tag picker: the same floating pane as Move, over the same dimmed scrim. Lists the tags
    /// Settings holds, with the one this entry already carries marked, and **No Tag** to take it
    /// off again.
    @ViewBuilder
    private func tagOverlay(ids: Set<UUID>) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy(duration: 0.22)) { taggingIDs = nil } }
            tagPane(ids: ids)
                .wwPane()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func tagPane(ids: Set<UUID>) -> some View {
        let current = currentTag(of: ids)
        VStack(spacing: 0) {
            Text("Tag")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WW.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            WWHairline()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(tags) { tag in
                        tagRow(tag.name, isOn: current == tag.name,
                               swatch: WW.tagColor(tag.colorID)) {
                            apply(tag: tag.name, to: ids)
                        }
                        WWHairline().padding(.leading, 16)
                    }
                    tagRow("No Tag", isOn: current == nil, tint: WW.inkSecondary) {
                        apply(tag: nil, to: ids)
                    }
                    if tags.isEmpty {
                        Text("Add tags in Settings → Inbox Tags.")
                            .font(.caption)
                            .foregroundStyle(WW.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func tagRow(_ title: String, isOn: Bool, tint: Color = WW.ink, swatch: Color? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 10, height: 10)
                }
                Text(title).foregroundStyle(tint)
                Spacer(minLength: 8)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WW.moss)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The tag these entries share, or nil when they don't share one (or carry none).
    private func currentTag(of ids: Set<UUID>) -> String? {
        let tags = Set(recordings.filter { ids.contains($0.id) }.map(\.tag))
        return tags.count == 1 ? tags.first ?? nil : nil
    }

    private func apply(tag: String?, to ids: Set<UUID>) {
        withAnimation(.snappy(duration: 0.22)) {
            model.setTag(tag, forRecordings: ids, in: documentID)
            taggingIDs = nil
            exitSelection()
        }
        WWHaptics.light()
    }

    // MARK: Move-to-document pane

    /// Floating pane (swipe a recording left → Move, or batch "Move"): the same design as the
    /// document Transform pane — a dimmed scrim you tap to dismiss, with the pane anchored at the
    /// bottom. A "New Document" button sits at the top, above the list of destination documents: it
    /// opens the rename step and then moves the recording(s) into the fresh document — the one
    /// choice that is always there, so it doesn't move down the pane as documents pile up (or get
    /// scrolled to at all).
    @ViewBuilder
    private func moveOverlay(ids: Set<UUID>) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy(duration: 0.22)) { movingIDs = nil } }
            movePane(ids: ids)
                .wwPane()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The pane body: a "Move to Document" header, a "New Document" row, then one row per
    /// destination document. "New Document" leads because it's the one destination that's always
    /// available — a long list of documents would otherwise push it out of sight below the scroll.
    @ViewBuilder
    private func movePane(ids: Set<UUID>) -> some View {
        VStack(spacing: 0) {
            Text("Move to Document")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WW.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            WWHairline()
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { movingIDs = nil }
                        startNewDocument(for: ids)
                    } label: {
                        Label("New Document", systemImage: "plus")
                            .foregroundStyle(WW.moss)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The hairline goes *above* each destination — under "New Document" and between
                    // the documents — so the list doesn't end on a rule against the pane's edge.
                    ForEach(documentTargets) { target in
                        WWHairline().padding(.leading, 16)
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                model.documents.moveRecordings(ids, from: documentID, to: target.id)
                                movingIDs = nil
                                exitSelection()
                            }
                        } label: {
                            Text(target.title)
                                .foregroundStyle(WW.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    // MARK: New document (from a swipe or a batch selection)

    /// Open the "Rename document" step, pre-filling the title with a suggested name drawn from the
    /// recordings being filed away.
    /// `titled` is the name to open the rename step with when there's a better one than the entries
    /// themselves can suggest — the tag, when a whole filter is being made into a document, since
    /// that's the word you'd have written yourself.
    private func startNewDocument(for ids: Set<UUID>, titled: String? = nil) {
        guard let seed = recordings.first(where: { ids.contains($0.id) }) else { return }
        newDocTitle = titled ?? suggestedDocumentTitle(for: seed)
        pendingNewDocIDs = ids
    }

    /// Confirm the rename step: create the document under the chosen title, move the recording(s)
    /// into it, and seed the body with their transcripts (so the new document reads like the
    /// recordings without needing a manual "Reset with Originals").
    private func confirmNewDocument() {
        guard let ids = pendingNewDocIDs else { return }
        let trimmed = newDocTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let doc = model.documents.createDocument(title: trimmed.isEmpty ? "New Document" : trimmed)
        model.documents.moveRecordings(ids, from: documentID, to: doc.id)
        model.resetWithOriginals(in: doc.id)
        pendingNewDocIDs = nil
        exitSelection()
    }

    /// A suggested title for a document seeded from `recording`: the first two words of its
    /// transcript, or — if it hasn't been transcribed yet — its capture time, e.g. "Aug 2, 2:15pm".
    private func suggestedDocumentTitle(for recording: Recording) -> String {
        let transcript = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !transcript.isEmpty {
            let words = transcript.split(whereSeparator: \.isWhitespace).prefix(2)
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: recording.createdAt)
    }

    private func enterSelection(with id: UUID) {
        guard !selectionMode else { return }
        finishEditing()          // batch actions and an open editor don't share the bottom bar
        selectionMode = true
        selected = [id]
    }

    private func exitSelection() {
        selectionMode = false
        selected = []
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// "Select All" means all of what's *shown*: with a filter on, the entries under it.
    private func selectAll() {
        let all = Set(visibleRecordings.map(\.id))
        selected = (selected == all) ? [] : all
    }

    private func copySelected() {
        let text = recordings
            .filter { selected.contains($0.id) }
            .compactMap { $0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        wwLog("Copied \(selected.count) recording transcript(s) to clipboard", .general)
    }

    /// Copy one recording's transcript. An untranscribed clip is left alone rather than wiping
    /// whatever is already on the clipboard.
    private func copy(_ recording: Recording) {
        let text = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            wwLog("Nothing to copy — “\(recording.name)” has no transcript yet", .general)
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        wwLog("Copied transcript of “\(recording.name)”", .general)
    }
}

/// One Inbox row. No play control — the transcript is the point here, so it runs the full width of
/// the row (the audio is still reachable from the editor's Share button). Only the selection
/// checkmark takes space to its left, and only while selecting.
///
/// Tapping the text opens it for editing **in place**: the preview gives way to `editor` — the
/// outlined edit box the Inbox hands down, with its own actions inside the outline — and the row's
/// own controls stand aside while it's open.
private struct InboxRecordingRow<Editor: View>: View {
    let recording: Recording
    let selectionMode: Bool
    let isSelected: Bool
    let isTransforming: Bool
    /// Whether that transform is still in its reasoning stage rather than writing the answer.
    let isThinking: Bool
    let isEditing: Bool
    /// Whether this entry is showing all of its transcript rather than the first few lines.
    let isExpanded: Bool
    let onTapLabel: () -> Void
    let onDoubleTapLabel: () -> Void
    let onLongPress: () -> Void
    let onCopy: () -> Void
    let onRetranscribe: () -> Void
    let moveTargets: [Document]
    let onMove: (Document) -> Void
    /// The ink this entry's tag is drawn in — the Inbox looks it up, since it's the one that reads
    /// the setting the colours live in.
    var tagColor: Color = WW.moss
    @ViewBuilder var editor: Editor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isSelected ? WW.moss : WW.inkTertiary)
            }

            // A few lines of the transcript over the capture date/time — **tap** to see the rest of
            // it, **double-tap** to edit it (or either, to toggle the row, when selecting). While
            // editing, the editor takes the preview's place.
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    editor
                } else if isTransforming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(isThinking ? "Thinking…" : "Transforming…")
                            .font(.subheadline)
                            .foregroundStyle(WW.inkSecondary)
                    }
                } else {
                    RecordingLabel(recording: recording, lineLimit: isExpanded ? nil : 8)
                }
                // The capture time, and — for an entry that's been filed — what it was filed as.
                // Small and beside the date rather than over the text: it's a note about the entry,
                // not part of what the entry says.
                HStack(spacing: 6) {
                    if let tag = recording.tag {
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tagColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tagColor.opacity(0.12), in: Capsule())
                    }
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(WW.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(TapsUnless(disabled: isEditing, tap: onTapLabel, doubleTap: onDoubleTapLabel))

            if !selectionMode && !isEditing {
                Menu {
                    // Nothing to re-run speech-to-text over when the entry arrived as text.
                    if !recording.isTextOnly {
                        Button("Retranscribe", systemImage: "arrow.clockwise", action: onRetranscribe)
                    }
                    if recording.transcript?.isEmpty == false {
                        Button("Copy Transcript", systemImage: "doc.on.doc", action: onCopy)
                    }
                    if !moveTargets.isEmpty {
                        Menu("Move to Document…") {
                            ForEach(moveTargets) { target in
                                Button(target.title) { onMove(target) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(WW.inkTertiary)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .modifier(LongPressUnless(disabled: isEditing, action: onLongPress))
    }
}

/// Attaches the row's two taps — one to reveal the whole transcript, two to edit it — and only
/// when `disabled` is false: an open editor needs its taps for the caret, so the gestures have to be
/// absent rather than merely ignored.
///
/// The double tap is attached *first*. SwiftUI hands a touch to the last gesture that can take it,
/// so with the single tap on the outside a second tap would never be waited for.
private struct TapsUnless: ViewModifier {
    let disabled: Bool
    let tap: () -> Void
    let doubleTap: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled {
            content
        } else {
            content
                .onTapGesture(count: 2, perform: doubleTap)
                .onTapGesture(perform: tap)
        }
    }
}

/// The long-press counterpart of `TapsUnless`: an open editor keeps its long press for the text
/// view's selection handles rather than entering batch selection.
private struct LongPressUnless: ViewModifier {
    let disabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled { content } else { content.onLongPressGesture(perform: action) }
    }
}

/// The **⋯** menu's joint-document row, the same in a document as in a graph: make the half this
/// one hasn't got, or let the pair go. It's one item because it's one idea — whether this document
/// is open beside its counterpart — and the same words in both places mean it reads the same way
/// whichever half you happen to be looking at.
struct JointDocumentMenuItem: View {
    let isJoined: Bool
    let onCreate: () -> Void
    let onSeparate: () -> Void

    var body: some View {
        if isJoined {
            Button(role: .destructive, action: onSeparate) {
                Label("Separate Joint Document", systemImage: "rectangle.split.2x1.slash")
            }
        } else {
            Button(action: onCreate) {
                Label("Create Joint Document", systemImage: "rectangle.split.2x1")
            }
        }
    }
}

/// Carries whatever the editor's Share button is handing to the system share sheet — the
/// transcript's text or the recording's audio file — through one `.sheet(item:)`.
private struct ShareTarget: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - Joint documents

/// A **joint document**: one document and one graph, open at the same time — prose down one side
/// and a mind map down the other, two ways of holding one subject rather than one container trying
/// to be both.
///
/// The halves are ordinary documents throughout. Each keeps its own recordings, its own Auto
/// transform, its own backup file and its own `.wwdoc` export; a link on one of them is the whole
/// of the pairing, and "Separate Joint Document" is nothing but clearing it. That's why each half
/// is shown here as *itself* — `DocumentDetailView` and `GraphDocumentView`, told only that they're
/// embedded, which makes each float the **⋯** menu it would have put in a navigation bar over its
/// own top-right corner instead. (No titles: the row you tapped said what this is, and two title
/// bars would spend a good part of a shared screen saying it again.) Neither half is given a
/// `NavigationStack` to hold a bar of its own: nesting
/// one inside the stack the Documents list drives by a typed path is what ends in
/// `AnyNavigationPath.Error.comparisonTypeMismatch`, and the framework meets that with a `try!`.
///
/// Which pane goes where is decided by what the halves *are*, not by which one was made first —
/// and it isn't the same answer on both axes. With room **across**, prose takes the left, where a
/// column of it reads, and opens at a third of the width, since a canvas needs room to be a canvas.
/// Stacked **down**, the canvas takes the top — it's panned and pinched with a whole hand — and the
/// document sits under it, where the keyboard comes up from anyway.
///
/// Nothing pushes this screen. It's what the Documents list's own route resolves to while the
/// document it names has a partner, so making a pair from inside a half turns that half into this,
/// and separating turns it back — without a second navigation style in a stack that already has
/// one, which is a mismatch SwiftUI treats as fatal rather than as a layout to sort out.
struct JointDocumentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The half that was open when the pair was made, and the one made for it. Which is which
    /// doesn't matter past this point — the two are sorted by kind below.
    let documentID: UUID
    let partnerID: UUID

    /// How much of the screen the **leading** half takes, as a fraction — dragged by the divider and
    /// remembered. Which half leads depends on the axis (see `body`): across it's the document, down
    /// it's the graph.
    ///
    /// Two settings rather than one, because across and down are different questions — how you like
    /// an iPad's two columns says nothing about how you like a phone's two rows — and they don't
    /// even hold the same half. Across, the document opens at a third: prose is a column and reads
    /// happily in one, while a canvas wants room to be a canvas.
    @AppStorage("jointSplitAcross") private var splitAcross = 1.0 / 3.0
    @AppStorage("jointSplitDown") private var splitDown = 0.5
    /// Where the fraction stood when the current drag began, so a drag moves *from* there rather
    /// than accumulating over itself.
    @State private var splitAtDragStart: Double?

    /// Which halves are on screen: both, or one of them filling the pair's place.
    ///
    /// Remembered across documents, like the divider — it's a statement about how you're working
    /// right now ("I'm writing", "I'm mapping") rather than a property of one pair, and the toggle
    /// that changed it is sitting in the corner of whatever you open next.
    @AppStorage("jointViewMode") private var viewModeID = JointViewMode.split.rawValue
    private var viewMode: JointViewMode { JointViewMode(rawValue: viewModeID) ?? .split }

    /// The prose half and the canvas half, whichever way round they were handed in.
    private var halves: (document: UUID, graph: UUID)? {
        guard let a = model.documents.document(with: documentID),
              let b = model.documents.document(with: partnerID) else { return nil }
        if a.isGraph == b.isGraph { return nil }          // two of a kind is not a pair
        return a.isGraph ? (b.id, a.id) : (a.id, b.id)
    }

    var body: some View {
        Group {
            if let halves {
                GeometryReader { geo in
                    let across = sizeClass == .regular
                    // The leading half's share of what's left after the divider takes its own width.
                    let room = (across ? geo.size.width : geo.size.height) - Self.dividerThickness
                    let first = max(room * split, 0)
                    switch viewMode {
                    case .document:
                        DocumentDetailView(documentID: halves.document, isEmbedded: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .graph:
                        GraphDocumentView(documentID: halves.graph, isEmbedded: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .split:
                        if across {
                            // Across, prose leads: a document is a column and reads left to right.
                            HStack(spacing: 0) {
                                DocumentDetailView(documentID: halves.document, isEmbedded: true)
                                    .frame(width: first)
                                divider(across: true, room: room)
                                GraphDocumentView(documentID: halves.graph, isEmbedded: true)
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            // Down, the canvas leads. A graph is panned and pinched with a whole
                            // hand, which wants the top of the phone; the document below it is read
                            // and typed into, which is where the keyboard comes up from anyway.
                            VStack(spacing: 0) {
                                GraphDocumentView(documentID: halves.graph, isEmbedded: true)
                                    .frame(height: first)
                                divider(across: false, room: room)
                                DocumentDetailView(documentID: halves.document, isEmbedded: true)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                    }
                }
            } else {
                WWEmptyState(title: "Joint document not found",
                             systemImage: "rectangle.split.2x1")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WW.paper)
            }
        }
        // The pair's own bar carries nothing but the way back: everything you can do to either half
        // is in that half's own menu, including separating the two.
        //
        // Nothing here watches for the pair being separated, and nothing dismisses. This screen is
        // what the route `Route.document(id)` *resolves to* while that document has a partner, so
        // separating from inside a pane resolves it back to the single half on its own — the way it
        // arrived. One navigation style, one source of truth, no stack to unwind by hand.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // The one thing the pair's own bar carries. It goes in the **bar** rather than floating over
        // the content: it's a statement about the whole screen, and the bar is where the screen's
        // own controls live — the way back at its left, the system's window control in the middle,
        // this at its right. Floating it inset put a control about the pair inside one of the
        // panes, where it read as that pane's.
        .toolbar {
            if halves != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    viewToggle(across: sizeClass == .regular)
                }
            }
        }
    }

    /// How much of the pair the leading half takes right now, on whichever axis this is.
    private var split: Double {
        min(max(sizeClass == .regular ? splitAcross : splitDown, Self.minimumSplit),
            1 - Self.minimumSplit)
    }

    /// The line between the halves, and the thing you take hold of to move it: a hairline with a
    /// grip on it, in a strip wide enough for a fingertip. Dragging it re-sizes both panes at once
    /// and the fraction is kept, so the way you like to split them is how they open next time.
    ///
    /// Neither half is allowed below a fifth of the screen — a pane too small to read is a pane you
    /// have to drag back out again, and the divider is the only way to do it.
    @ViewBuilder
    private func divider(across: Bool, room: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(WW.hairline)
                .frame(width: across ? 1 : nil, height: across ? nil : 1)
            Capsule()
                .fill(WW.inkTertiary.opacity(0.7))
                .frame(width: across ? 4 : 40, height: across ? 40 : 4)
        }
        .frame(width: across ? Self.dividerThickness : nil,
               height: across ? nil : Self.dividerThickness)
        .frame(maxWidth: across ? nil : .infinity, maxHeight: across ? .infinity : nil)
        .background(WW.paper)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    guard room > 0 else { return }
                    let start = splitAtDragStart ?? split
                    splitAtDragStart = start
                    let moved = across ? value.translation.width : value.translation.height
                    let next = min(max(start + moved / room, Self.minimumSplit),
                                   1 - Self.minimumSplit)
                    if sizeClass == .regular { splitAcross = next } else { splitDown = next }
                }
                .onEnded { _ in splitAtDragStart = nil }
        )
        .accessibilityLabel("Resize the two halves")
    }

    // MARK: The view toggle

    /// **Document · Split · Graph**, in the pair's top-right corner: one half, both, or the other.
    ///
    /// A joint document is two things open at once, which is the point of it — but not every moment
    /// wants both. Writing wants the page; mapping wants the canvas; and on a phone, where the two
    /// share the height, either one alone is most of what's worth having. So the pair keeps the
    /// answer to "which of you am I looking at" as a switch rather than as a divider dragged to the
    /// edge and back.
    ///
    /// It lives at the **trailing end of the navigation bar**, which is the pair's own row of
    /// chrome: the way back to Documents at its left, the system's window control in the middle,
    /// this at its right. Each *half* floats its **⋯** over its own corner below — a menu about
    /// that half — so nothing is stacked on anything. Split sits in the middle of the three,
    /// because it's the setting the two ends are named against: one, both, the other.
    private func viewToggle(across: Bool) -> some View {
        HStack(spacing: 0) {
            viewToggleSegment(.document, "doc.text", "Document only")
            viewToggleSegment(.split, across ? "rectangle.split.2x1" : "rectangle.split.1x2",
                              "Document and graph")
            viewToggleSegment(.graph, "point.3.connected.trianglepath.dotted", "Graph only")
        }
        // No track behind the three. The bar's own surface is the background, and the one filled
        // capsule is the whole of what the control has to say; a plate under all three said it
        // twice and made a small thing look heavy.
        .accessibilityElement(children: .contain)
    }

    /// One of the three. Filled in when it's the one you're looking at — the same "on" a canvas
    /// control wears, so a chosen thing looks chosen everywhere in the app.
    private func viewToggleSegment(_ mode: JointViewMode, _ icon: String,
                                   _ label: String) -> some View {
        let isOn = viewMode == mode
        return Button {
            guard !isOn else { return }
            withAnimation(.snappy(duration: 0.22)) { viewModeID = mode.rawValue }
            WWHaptics.light()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? WW.paper : WW.moss)
                .frame(width: 34, height: 26)
                .background(isOn ? WW.moss : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// How wide the grab strip is, and how little of the screen a half may be left with.
    private static let dividerThickness: CGFloat = 16
    private static let minimumSplit: Double = 0.2
}

/// Which halves of a joint document are on screen — see `JointDocumentView.viewToggle`. A raw
/// string because it's kept in `@AppStorage`, and a name on disk that says what it means survives
/// a reordering of the cases.
enum JointViewMode: String {
    case document
    case split
    case graph
}

// MARK: - Graph documents
//
// The graph canvas lives at the bottom of this file — rather than in one of its own — for the same
// reason the Inbox and the recorder do: `project.yml` globs `Apps/iOS` when the Xcode project is
// *generated*, so a new source file is invisible to an already-generated project until someone
// re-runs xcodegen. Everything below is self-contained; it just rides in on a file the target
// already compiles.

/// A **graph document**: a mind map on a pannable, zoomable canvas, as opposed to a document's
/// column of paragraphs.
///
/// • **Hold anywhere** on the canvas and a node appears under your finger and starts recording;
///   lift and it stops, transcribes, and the words drop into that node. One gesture, one node.
/// • **Double-tap** the canvas for a node you type into instead.
/// • A node is a small edit block: **tap twice** to edit it in place, **long-press** for the
///   actions a paragraph gets from a swipe, as a dropdown.
/// • **Drag** a node and its children come along; **drop it on another node** and the whole branch
///   hangs off that one instead.
/// • The **"+"** on a node's right edge adds a child; the one midway along a line inserts a node
///   between the two it joins. Tap either to type; **hold** either to record, the same way the
///   canvas does.
///
/// Nodes stay exactly where they're put. There's no simulation nudging them around: a graph you
/// arranged reads the same when you come back to it, and a node you're dragging onto another one
/// doesn't slide out from under it.
///
/// There's no red record button along the bottom — the hold *is* the record button — but the Auto
/// transform toggle is the same one the Inbox and documents carry, and applies to nodes the same
/// way (see `AppModel.captureGraphNode`).
struct GraphDocumentView: View {
    @EnvironmentObject private var model: AppModel
    /// The size transcription text is set in (Settings → Display) — a node's words here.
    @Environment(\.transcriptTextSize) private var transcriptTextSize: Double
    let documentID: UUID
    /// True when this canvas is one pane of a joint document — see `DocumentDetailView.isEmbedded`.
    var isEmbedded = false

    /// The recorder behind hold-to-record. (Revise uses the ordinary `RecordingSheet` instead —
    /// replacing a node deliberately deserves the pause/discard controls.)
    @StateObject private var recorder = AudioRecorder()

    // The canvas transform. `pan` is where the canvas origin sits in view coordinates, `scale` the
    // zoom. Both gestures move `pan` *incrementally*, never by re-deriving it from where they
    // started, which is what lets a pan and a pinch run at the same time without one erasing the
    // other's work.
    @State private var pan: CGPoint = .zero
    @State private var scale: CGFloat = 1
    @State private var lastPanTranslation: CGSize = .zero
    @State private var zoomAnchor: CGPoint?
    @State private var lastMagnification: CGFloat = 1
    @State private var canvasSize: CGSize = .zero
    @State private var didPlaceCanvas = false

    // The finger on the bare canvas: a pan, a hold that records, or a tap.
    @State private var phase: CanvasPhase = .idle
    /// The `startLocation` of the gesture `phase` is about. A gesture the system cancels never
    /// sends `onEnded`, so the phase is anchored to a gesture rather than trusted between them:
    /// the next touch to begin somewhere else takes over regardless of what was left behind.
    @State private var gestureStart: CGPoint?
    @State private var holdTask: Task<Void, Never>?
    @State private var recordingNodeID: UUID?
    /// Where the recording readout floats, in canvas-view points: the spot the hold began, so it
    /// can sit clear of the finger holding it.
    @State private var recordingAnchor: CGPoint?

    // A recording can run on into a chain without the finger ever lifting: a ring is drawn around
    // the node being spoken into, and leaving it files that clip and starts the next one.
    /// The ring's centre, in view points — nil while a new node is still looking for its spot.
    @State private var chainRingCenter: CGPoint?
    /// The node following the finger until it settles, and where it currently sits (canvas points).
    @State private var chainFollowingNodeID: UUID?
    @State private var chainFollowPoint: CGPoint?
    @State private var settleTask: Task<Void, Never>?
    @State private var settleReference: CGPoint = .zero
    @State private var settleSince: Date = .distantPast
    @State private var lastTap: (at: Date, point: CGPoint)?
    /// The canvas coasting to a stop after a flick.
    @State private var glideTask: Task<Void, Never>?

    // Groups: the ring being dragged, the one under the pointer, and the one having its label
    // edited. The ring's *edge* is the only handle a group has — its middle is deliberately deaf,
    // so the cards inside stay reachable — which makes "where can I take hold of this" a real
    // question. Hovering one answers it before you press.
    @State private var draggingGroupID: UUID?
    @State private var hoveredGroupID: UUID?
    @State private var labelingGroupID: UUID?
    @State private var groupLabelText = ""

    // Selecting: the mode that turns a drag into a selection box, the box itself, and what it
    // caught. Selecting is a mode now rather than a gesture: the hold belongs to recording, which
    // needs it everywhere on the canvas, so picking several nodes out is asked for (⋯ → Select
    // Nodes) rather than discovered by holding still.
    @State private var isSelecting = false
    @State private var selectedNodeIDs: Set<UUID> = []
    @State private var marqueeOrigin: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    /// The ⌘ key, when there's a keyboard to hold it down with: held as a drag begins, that drag
    /// draws a selection box too, without the mode being switched on first.
    @State private var keys = ModifierKeys()
    /// The ⌘ and ⌥ as they're *held* — which is a different question from `keys` above: that one is
    /// read off a touch, and a touch is not what a hover or a key press is.
    ///
    /// Both sorts live here. The **hardware** keys are watched on the device (`ModifierKeyMonitor`),
    /// and so are the **buttons** beside the minimap, which a device with no keyboard holds down
    /// with one thumb while the other drags. The buttons aren't canvas state for the same reason
    /// the keys aren't: a **joint document** is two panes of one screen, and a soft key has to
    /// behave like the real one across both — holding ⌘ beside the canvas turns the document half's
    /// "+" into a caret, exactly as a hardware ⌘ does.
    @ObservedObject private var modifierKeys = ModifierKeyMonitor.shared
    /// The card the pointer is resting on. Tracked whenever there's a pointer, not only while ⌘ is
    /// engaged — otherwise pressing ⌘ with the pointer already over a card would raise nothing,
    /// since no hover event happens when a key goes down.
    @State private var hoveredNodeID: UUID?
    /// Whether the pointer is on the quick-action bar itself. The bar floats *above* the card, so
    /// reaching it means leaving the card — and letting go of the card the instant the pointer
    /// crosses the gap took the bar away before it could be clicked. See `holdQuickActions`.
    @State private var hoveringQuickActions = false
    /// The clock that lets a card's quick actions go once nothing is pointing at either of them.
    @State private var quickActionsTask: Task<Void, Never>?
    /// The card a *tap* asked for actions on, which is what a finger has instead of a hover.
    @State private var tappedNodeID: UUID?
    /// Whether this canvas is the screen you're on. Navigating away leaves it in the hierarchy, so
    /// the keyboard shortcuts ask this before answering — see `acceptsKeyCommands`.
    @State private var isOnScreen = true

    /// Which card's quick actions are showing. The pointer wins when there is one: it's the more
    /// recent statement of intent, and it moves away on its own.
    private var quickActionNodeID: UUID? { hoveredNodeID ?? tappedNodeID }
    /// Whether the touch in progress is the second of a pair — the one that makes a node to type
    /// into, if it's let go rather than held (holding records, wherever the finger is).
    @State private var isSecondTouch = false

    // Dragging a branch. The translation lives here until the finger lifts; only then is it written
    // to the nodes, so a drag is one edit rather than sixty.
    @State private var draggingNodeID: UUID?
    /// The card whose gesture is driving the drag, which is not always the card being moved: an ⌥
    /// drag hands the movement to a fresh copy while the events keep arriving from the original.
    @State private var dragSourceID: UUID?
    @State private var draggingBranch: Set<UUID> = []
    @State private var dragTranslation: CGSize = .zero
    @State private var dropTargetID: UUID?
    /// What the modifier held as this drag began made of it. A drag is one gesture with one
    /// meaning, decided when it starts: **⌘** pulls the node out of the network as it moves, **⌥**
    /// pulls a copy out of it, and neither one changes its mind half way across the canvas because
    /// a thumb slipped off a key.
    @State private var dragMode: NodeDragMode = .move

    // Node editing, in place, in its own card.
    @State private var editingNodeID: UUID?
    @State private var editingText = ""
    @State private var editingSelection = NSRange(location: 0, length: 0)

    // The long-press dropdown, the transform picker, and the transforms running right now.
    @State private var menuNodeID: UUID?
    @State private var transformTargetID: UUID?
    @State private var transformingNodeIDs: Set<UUID> = []
    @State private var reviseTask: ReviseTask?

    /// Measured card sizes, so a drop lands on the node it looks like it lands on and the "+" sits
    /// on the actual edge rather than an assumed one.
    @State private var nodeSizes: [UUID: CGSize] = [:]

    /// The minimap along the bottom, and the list of nodes. The minimap is remembered across
    /// graphs — it's a preference about how you like to work, not about one document — and starts
    /// **off**: the canvas's whole point is that it runs to the edge, and a map of a graph you can
    /// already see is a strip of screen spent on nothing. ⋯ → Show Minimap when you want it.
    @AppStorage("graphShowsMinimap") private var showsMinimap = false
    @State private var showingNodeList = false
    /// The node the list has just sent you to, ringed for a moment so the eye can find it among
    /// however many cards the canvas slid across, and the clock that lets go of it again.
    @State private var highlightedNodeID: UUID?
    @State private var highlightTask: Task<Void, Never>?

    /// A phone shows the node list as a sheet over the canvas; anything wider shows it as a sidebar
    /// down the right, where it can stay open while you work — the list is a way *around* the
    /// canvas, and on an iPad there's room to keep it beside what it's pointing at.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var showsNodeSidebar: Bool { sizeClass == .regular }

    /// Auto tidy: with it on, adding a node lines its siblings up around it — "Tidy Children" run
    /// for you, every time, instead of when you ask. Remembered across graphs for the same reason
    /// the minimap is: it's how you like to work rather than a property of one mind map. Off by
    /// default, since a graph otherwise never moves a node you placed.
    @AppStorage("graphAutoTidy") private var autoTidy = false
    /// Parents whose children a tidy is owed to, held until the finger lifts: a card must not slide
    /// out from under the touch that's still recording into it.
    @State private var pendingTidyParents: Set<UUID> = []

    // Title, sharing.
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var shareItem: ShareItem?
    @State private var documentFileShare: DocumentFileShareItem?

    private var document: Document? { model.documents.document(with: documentID) }

    var body: some View {
        Group {
            if let document {
                HStack(spacing: 0) {
                    canvas(for: document)
                    if showsNodeSidebar, showingNodeList {
                        // `WWHairline` is a horizontal rule; this one stands up.
                        Rectangle().fill(WW.hairline).frame(width: 1)
                        nodeListSidebar(for: document)
                            .frame(width: GraphCanvas.nodeListWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                WWEmptyState(title: "Graph not found", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WW.paper)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isEmbedded { paneMenu(for: document) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !isEmbedded { toolbarContent(for: document) } }
        // No bottom bar here. A graph has no record button — the hold on the canvas is it — and its
        // Auto transform is an app-wide setting ("Auto transform nodes", in Settings → Graphs)
        // rather than a per-document toggle, so the canvas runs all the way down to the edge.
        // Leaving commits the open editor, and closes off a hold that never got its finger back (a
        // gesture the system cancelled, a screen left mid-recording) — which would otherwise leave
        // the recorder running behind a node that says "Recording" for ever.
        .onDisappear {
            isOnScreen = false
            cancelHold()
            stopGlide()
            if recordingNodeID != nil { finishHoldRecording() }
            resetChain()
            phase = .idle
            gestureStart = nil
            isSelecting = false
            modifierKeys.virtualCommand = false
            modifierKeys.virtualOption = false
            modifierKeys.virtualShift = false
            quickActionsTask?.cancel()
            hoveringQuickActions = false
            hoveredNodeID = nil
            hoveredGroupID = nil
            draggingGroupID = nil
            tappedNodeID = nil
            marqueeOrigin = nil
            marqueeCurrent = nil
            pendingTidyParents = []
            highlightTask?.cancel()
            highlightedNodeID = nil
            finishEditing()
        }
        .sheet(item: $reviseTask) { task in
            RecordingSheet(title: "Revise Node",
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                model.captureGraphNode(audioURL: url, duration: duration,
                                       nodeID: task.nodeID, in: documentID)
            }
        }
        .sheet(isPresented: nodeListSheetPresented) {
            if let document { nodeListSheet(for: document) }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.text])
        }
        .sheet(item: $documentFileShare) { item in
            ActivityView(activityItems: [item.url])
        }
        .sheet(isPresented: Binding(get: { labelingGroupID != nil },
                                    set: { if !$0 { labelingGroupID = nil } })) {
            groupSheet()
        }
        .alert("Rename graph", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let document, !trimmed.isEmpty { model.documents.rename(document, to: trimmed) }
            }
            Button("Cancel", role: .cancel) { }
        }
        // One node's Transform, from the dropdown or from inside the open editor.
        .confirmationDialog("Transform — \(AppSettings.shared.model.shortName)",
                            isPresented: Binding(get: { transformTargetID != nil },
                                                 set: { if !$0 { transformTargetID = nil } }),
                            titleVisibility: .visible) {
            if let id = transformTargetID {
                ForEach(model.documents.presets) { preset in
                    Button(preset.name) { runTransform(preset, nodeID: id) }
                }
            }
        }
    }

    // MARK: The canvas

    @ViewBuilder
    private func canvas(for document: Document) -> some View {
        GeometryReader { geo in
            // Every card's rectangle, worked out once for the whole pass and handed to everything
            // that needs one — the edges, the group rings, the cards, and the minimap, which draws
            // the very same curves. A drag re-runs this body on every frame, and looking each node
            // up again per edge and per ring made that quadratic in the size of the graph.
            let boxes = cardBoxes(in: document)
            let lines = edges(of: document, boxes: boxes)
            content(for: document, boxes: boxes, lines: lines)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(alignment: .topLeading) { GraphGrid(pan: pan, scale: scale) }
                .background(WW.paper)
                // Nothing to see: one watches the window for the modifiers held as a touch goes
                // down, the other holds the keyboard so Delete, ⌘←/→ and ⌘T reach the canvas.
                .background { commandKeyWatcher() }
                .background { keyCommands() }
                .clipped()
                .contentShape(Rectangle())
                // The canvas's own gestures. A touch that lands on a node is the node's — SwiftUI
                // gives a child's gesture priority over its ancestors' — so this only ever sees the
                // bare canvas.
                .gesture(canvasGesture())
                .simultaneousGesture(zoomGesture())
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        selectionBar()
                        bottomControls(for: document, edges: lines)
                    }
                }
                .overlay { chainRing() }
                .overlay { recordingReadout(in: geo.size) }
                .overlay(alignment: .topLeading) { menuOverlay(for: document, in: geo.size) }
                .overlay(alignment: .topLeading) { quickActions(for: document, in: geo.size) }
                .overlay {
                    if document.nodes.isEmpty {
                        WWEmptyState(title: "An empty canvas",
                                     systemImage: "point.3.connected.trianglepath.dotted",
                                     message: "Hold anywhere to record a node — it appears under your finger and stops when you lift it. Double-tap to type one instead.")
                    }
                }
                .onAppear {
                    canvasSize = geo.size
                    isOnScreen = true
                    placeCanvas(in: geo.size, document: document)
                    // Whatever a previous visit left behind, this one starts with nothing in
                    // progress — otherwise a gesture cut short back then would keep the next hold
                    // from ever arming.
                    phase = .idle
                    gestureStart = nil
                }
                .onChange(of: geo.size) { _, size in canvasSize = size }
        }
    }

    /// Everything drawn in canvas coordinates: the lines, the "+" on each of them, and the nodes.
    /// One transform is applied to the lot — `scaleEffect` then `offset` — so a canvas point `c`
    /// lands at `c * scale + pan` and `canvasPoint(for:)` is its exact inverse.
    @ViewBuilder
    private func content(for document: Document, boxes: [UUID: CGRect],
                         lines: [GraphEdgeLine]) -> some View {
        ZStack(alignment: .topLeading) {
            // Rings first, so they sit behind the cards they're drawn around — and widest first, so
            // a ring nested inside another has its own edge (and its label) on top of the one
            // around it rather than underneath.
            let rings = groupRings(in: document, boxes: boxes)
            ForEach(rings.order) { group in
                if let frame = rings.frames[group.id] {
                    groupView(group, frame: frame)
                }
            }

            GraphEdgeShape(edges: lines)
                .stroke(WW.inkTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .allowsHitTesting(false)

            if !isPickingOut {
                ForEach(lines) { edge in
                    HoldablePlusButton(onTap: { insertNode(on: edge) },
                                       onHold: {
                                           holdRecord(at: edge.midpoint) {
                                               model.documents.insertNode(between: edge.parentID,
                                                                          and: edge.id,
                                                                          in: documentID)
                                           }
                                       },
                                       onRelease: {
                                           finishHoldRecording()
                                           flushPendingTidy()
                                       })
                        .accessibilityLabel("Insert node between")
                        .position(x: edge.midpoint.x + GraphCanvas.center,
                                  y: edge.midpoint.y + GraphCanvas.center)
                }
            }

            ForEach(document.nodes) { node in
                nodeView(node, in: document, center: point(of: node))
            }

            if let box = marqueeRect {
                Rectangle()
                    .fill(WW.moss.opacity(0.10))
                    .overlay(Rectangle().stroke(WW.moss.opacity(0.65),
                                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .frame(width: max(box.width, 1), height: max(box.height, 1))
                    .position(x: box.midX + GraphCanvas.center, y: box.midY + GraphCanvas.center)
                    .allowsHitTesting(false)
                    .zIndex(3)
            }
        }
        .frame(width: GraphCanvas.extent, height: GraphCanvas.extent, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: pan.x - GraphCanvas.center * scale, y: pan.y - GraphCanvas.center * scale)
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeView(_ node: GraphNode, in document: Document, center: CGPoint) -> some View {
        let isEditing = editingNodeID == node.id
        let card = nodeCard(node, in: document, isEditing: isEditing)
            // The open editor is given a little more room than a card at rest: it has to hold the
            // text *and* the action row along the bottom of its outline.
            .frame(width: isEditing ? GraphCanvas.editingNodeWidth : GraphCanvas.nodeWidth,
                   alignment: .leading)
            .background { sizeReader(for: node.id) }
            .overlay(alignment: .trailing) {
                // Nothing on the canvas adds nodes while selecting — the "+" would be one stray
                // fingertip away from a card nobody asked for, in the middle of picking cards out.
                if !isEditing, !isPickingOut {
                    HoldablePlusButton(onTap: { addChild(to: node) },
                                       onHold: {
                                           holdRecord(at: CGPoint(x: center.x + GraphCanvas.nodeWidth / 2,
                                                                  y: center.y)) {
                                               model.documents.addChildNode(to: node.id, in: documentID)
                                           }
                                       },
                                       onRelease: {
                                           finishHoldRecording()
                                           flushPendingTidy()
                                       })
                        .accessibilityLabel("Add child node")
                        // Centred on the card's right edge, half in and half out: it's the seam a
                        // child grows from, and it reads that way sitting *on* it rather than
                        // tucked inside. Half the button's target width does it, the overlay
                        // having put its trailing edge on the card's.
                        .offset(x: HoldablePlusButton.target / 2)
                }
            }

        Group {
            if isEditing {
                // The open editor keeps every gesture to itself: a double tap selects a word, a long
                // press raises the selection handles, a drag moves the caret.
                card
            } else if isPickingOut {
                // While selecting — the mode, or the ⌘ button held — a card is something to pick
                // rather than something to open: one tap takes it in or out of the selection, and
                // brings up the two things worth doing to one node without leaving the mode.
                // With a pointer, pointing at the card is enough. Dragging still moves the lot.
                card
                    .onTapGesture {
                        toggleSelection(of: node)
                        withAnimation(.snappy(duration: 0.15)) { tappedNodeID = node.id }
                    }
                    .highPriorityGesture(nodeDrag(node, in: document))
            } else {
                card
                    .onTapGesture(count: 2) { startEditing(node) }
                    // 3 points, not the default 10: once you've started moving, you're dragging,
                    // and a menu that opens out from under a card already on its way is a menu
                    // nobody asked for.
                    .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 3) {
                        openMenu(for: node)
                    }
                    // **High priority, and that's what makes a drag start when it starts.**
                    //
                    // Gesture modifiers on one view are tried in the order they were attached, and
                    // a plain `.gesture` here is attached last — so the double tap and the long
                    // press each got first refusal, and a drag couldn't begin until both had
                    // *failed*. Both fail on movement, and a tap's allowance for it is around ten
                    // points with no way to set it from `onTapGesture`. So the card sat still for
                    // the first ten points of every drag and then jumped to catch up: the hang.
                    //
                    // Raising the drag inverts the order without taking anything away. A tap
                    // doesn't travel four points, so the drag never begins during one and the tap
                    // still fires; a press held still never moves at all, so the menu still opens.
                    // Only a touch that actually goes somewhere is claimed, which is the touch that
                    // meant to.
                    .highPriorityGesture(nodeDrag(node, in: document))
            }
        }
        // Hover is watched in every mode, not only while picking out: a pointer resting on a card
        // when ⌘ goes down has already sent its hover event, and won't send another.
        .onHover { inside in
            if inside { pointAt(node.id) } else { releaseQuickActions(of: node.id) }
        }
        .position(x: center.x + GraphCanvas.center, y: center.y + GraphCanvas.center)
        // Whatever is travelling rides over what isn't — the whole branch, not just the card under
        // the finger, and a fresh ⌥ copy over the original it came out of.
        .zIndex(isEditing || draggingBranch.contains(node.id) ? 2 : 1)
    }

    /// A node: the same edit block a paragraph or an Inbox entry becomes, shrunk to a card.
    @ViewBuilder
    private func nodeCard(_ node: GraphNode, in document: Document, isEditing: Bool) -> some View {
        if isEditing {
            WWInlineEditBox(onDone: { finishEditing() }) {
                // The heading is read off the buffer rather than the stored node, so the editor is
                // set the size the card was — and grows the moment you type a `#` in front of it.
                InlineTextEditor(text: $editingText, selection: $editingSelection, style: .graphNode,
                                 heading: GraphHeading.parse(editingText),
                                 onSubmit: { finishEditing() })
            } actions: {
                // The ink first, where the same dot sits on a group's ring: it's what this card
                // *is* rather than something to do to it, so it leads the row.
                GraphColorDot(colorID: node.colorID) { colorID in
                    model.documents.setNodeColor(node.id, in: documentID, to: colorID)
                }
                WWInlineEditAction("Revise", "mic.fill") { reviseEditingNode() }
                WWInlineEditAction("Transform", "wand.and.stars", enabled: model.modelReady) {
                    transformEditingNode()
                }
                WWInlineEditAction("Tidy Children", "rectangle.3.group",
                                   enabled: !document.children(of: node.id).isEmpty) {
                    tidyChildren(of: node)
                }
                WWInlineEditAction("Delete", "trash", tint: WW.ember) { deleteEditingNode() }
            }
        } else {
            nodeLabel(node, in: document)
                .padding(.leading, 12)
                // The "+" straddles the right edge now, so the text only has to clear the half of
                // it that's inside the card — 11 points of dot, and a little air.
                .padding(.trailing, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { nodeBackground(node) }
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(nodeBorder(node), lineWidth: nodeBorderWidth(node)))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }

    /// The card's own surface, with the node's ink laid over it as a wash where it has one. Two
    /// fills rather than one blended colour: the tint has to sit on the card's surface in both
    /// light and dark, and "the same green, faintly" is exactly what a wash is. The wash is a view
    /// that comes and goes, so taking a colour off takes the wash with it.
    @ViewBuilder
    private func nodeBackground(_ node: GraphNode) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape
            .fill(WW.surface)
            .overlay {
                if let wash = WW.paletteColor(node.colorID) {
                    shape.fill(wash.opacity(GraphCanvas.tintOpacity))
                }
            }
    }

    /// What a node says while it isn't being edited: its words, or why it hasn't any yet.
    @ViewBuilder
    private func nodeLabel(_ node: GraphNode, in document: Document) -> some View {
        let transform = transformState(of: node)
        if recordingNodeID == node.id {
            HStack(spacing: 8) {
                Circle().fill(WW.ember).frame(width: 10, height: 10)
                Text(Recording.durationLabel(recorder.elapsed))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(WW.ink)
                Text("Recording")
                    .font(.caption)
                    .foregroundStyle(WW.inkSecondary)
            }
        } else if transform.running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(transform.thinking ? "Thinking…" : "Transforming…")
                    .font(.caption)
                    .foregroundStyle(WW.inkSecondary)
            }
        } else if node.hasText {
            // A node that opens with `#` or `##` is a heading: bigger, bold, and with the marker
            // itself left out — you typed it to say "make this a heading", and the size on screen is
            // what it turned into. Open the node for editing and the marker is back, since that's
            // the text.
            // Never truncated: a card is as tall as what was said into it. A transcript cut off at
            // six lines is a node you have to open to read, which is a node that no longer says
            // what it says — and the canvas has room in every direction to hold the whole thing.
            Text(node.displayText)
                .font(nodeFont(node.heading))
                .foregroundStyle(WW.ink)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        } else {
            switch recording(for: node, in: document)?.status {
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing…").font(.caption).foregroundStyle(WW.inkSecondary)
                }
            case .pending:
                Text("Waiting to transcribe").font(.caption).foregroundStyle(WW.inkSecondary)
            case .failed:
                Text("Transcription failed").font(.caption).foregroundStyle(WW.amber)
            case .done, .none:
                Text("Empty — tap twice to write")
                    .font(.caption)
                    .foregroundStyle(WW.inkTertiary)
            }
        }
    }

    /// Whether this node's words are being rewritten right now, and whether that rewrite is still
    /// in its thinking stage. Two ways in: the node's own **Transform**, and the graph's app-wide
    /// **Auto transform** running over the clip the node was spoken into — which used to leave the
    /// card reading "Empty — tap twice to write" for the length of it.
    private func transformState(of node: GraphNode) -> (running: Bool, thinking: Bool) {
        if transformingNodeIDs.contains(node.id) {
            return (true, model.isThinking(node.id))
        }
        if let recordingID = node.recordingID, model.autoTransformingIDs.contains(recordingID) {
            return (true, model.isThinking(recordingID))
        }
        return (false, false)
    }

    /// The type a node's words are set in: the canvas's own size, or a heading's step up from
    /// it — bold, and as many points bigger as the marker asked for (`#` more than `##`).
    private func nodeFont(_ heading: GraphHeading?) -> Font {
        let base = InlineTextStyle.graphNode.pointSize(transcriptTextSize)
        guard let heading else { return .system(size: base) }
        return .system(size: base + CGFloat(heading.extraPoints), weight: .bold)
    }

    /// What a card's border says about it. What's *happening* outranks what it is: a recording, or a
    /// card being pulled out of the network right now, then the ring the node list leaves behind —
    /// amber precisely because nothing else here is: "this is the one you asked for", not "this is
    /// selected" — then the selection, and only then the ink the node was given.
    private func nodeBorder(_ node: GraphNode) -> Color {
        if recordingNodeID == node.id { return WW.ember }
        if dragMode.leavesGroups, draggingBranch.contains(node.id) { return WW.ember }
        if highlightedNodeID == node.id { return WW.amber }
        if dropTargetID == node.id || selectedNodeIDs.contains(node.id) { return WW.moss }
        return WW.paletteColor(node.colorID) ?? WW.hairline
    }

    private func nodeBorderWidth(_ node: GraphNode) -> CGFloat {
        if recordingNodeID == node.id || dropTargetID == node.id { return 2 }
        if dragMode.leavesGroups, draggingBranch.contains(node.id) { return 2 }
        if highlightedNodeID == node.id { return 3 }
        if selectedNodeIDs.contains(node.id) { return 2 }
        // A coloured card is drawn a hair heavier, so the colour is a border rather than a tint on
        // a hairline nobody can see.
        return node.colorID == nil ? 1 : 1.5
    }

    private func recording(for node: GraphNode, in document: Document) -> Recording? {
        guard let id = node.recordingID else { return nil }
        return document.recordings.first(where: { $0.id == id })
    }

    /// The drawn height of every card the canvas has measured. The arranging needs these: a gap
    /// between *centres* is not a gap you can see, and a card with six lines in it is twice the
    /// height of one with a word.
    private var measuredHeights: [UUID: Double] {
        nodeSizes.mapValues { Double($0.height) }
    }

    /// Report each card's measured size so drops and the right-edge "+" line up with what's drawn.
    private func sizeReader(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { nodeSizes[id] = proxy.size }
                .onChange(of: proxy.size) { _, size in nodeSizes[id] = size }
        }
    }

    // MARK: Edges

    /// The curve between a parent and a child, drawn between the **edges** of the two cards rather
    /// than their centres: each end is the midpoint of whichever side faces the other, so the line
    /// meets a card square-on and stops at its border instead of disappearing under it. Which side
    /// that is comes back with the anchor, since it's also the direction the curve sets off in.
    private func edges(of document: Document, boxes: [UUID: CGRect]) -> [GraphEdgeLine] {
        document.nodes.compactMap { node in
            guard let parentID = node.parentID,
                  let parentBox = boxes[parentID], let box = boxes[node.id] else { return nil }
            let start = anchor(of: parentBox, facing: box)
            let end = anchor(of: box, facing: parentBox)
            return GraphEdgeLine(id: node.id,
                                 parentID: parentID,
                                 from: start.point, facing: start.normal,
                                 to: end.point, entering: end.normal)
        }
    }

    /// The middle of whichever side of `box` is nearest the other card, and the way that side
    /// faces — each end of a line decided on its own, by measuring, rather than inferred from the
    /// angle between the two centres.
    ///
    /// The angle is the tempting test and it's wrong for cards this shape: a node card is three
    /// times wider than it is tall, so the line out of its centre leaves through the *top* as soon
    /// as the other node is more than about 18° above the horizontal — which is how a child sitting
    /// out to the right and a little high ended up joined top-to-bottom. Measuring each side against
    /// the other card's rectangle asks the question the eye is actually asking: which edge is
    /// closest to that node?
    private func anchor(of box: CGRect, facing target: CGRect) -> (point: CGPoint, normal: CGVector) {
        let sides: [(point: CGPoint, normal: CGVector)] = [
            (CGPoint(x: box.maxX, y: box.midY), CGVector(dx: 1, dy: 0)),      // right
            (CGPoint(x: box.minX, y: box.midY), CGVector(dx: -1, dy: 0)),     // left
            (CGPoint(x: box.midX, y: box.minY), CGVector(dx: 0, dy: -1)),     // top
            (CGPoint(x: box.midX, y: box.maxY), CGVector(dx: 0, dy: 1))       // bottom
        ]
        let nearest = sides.min {
            distance(from: $0.point, to: target) < distance(from: $1.point, to: target)
        }
        return nearest ?? (point: CGPoint(x: box.midX, y: box.midY), normal: CGVector(dx: 1, dy: 0))
    }

    /// How far a point is from the nearest part of a rectangle — zero inside it.
    private func distance(from point: CGPoint, to box: CGRect) -> CGFloat {
        let dx: CGFloat = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy: CGFloat = max(box.minY - point.y, 0, point.y - box.maxY)
        return hypot(dx, dy)
    }

    /// Where a node is: where it's stored — plus the live translation, if it's part of the branch
    /// currently under a finger.
    ///
    /// Takes the node rather than its id wherever the caller already has one. `Document.node(with:)`
    /// is a scan of the array, and this is asked on every frame of a drag for every card, every edge
    /// end and every ring: the id version is for the few places that genuinely only have an id.
    private func point(of node: GraphNode) -> CGPoint {
        // A node still looking for its place in a chain is wherever the finger is.
        if chainFollowingNodeID == node.id, let following = chainFollowPoint { return following }
        let base = CGPoint(x: node.position.x, y: node.position.y)
        guard draggingBranch.contains(node.id) else { return base }
        return CGPoint(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
    }

    private func point(of id: UUID, in document: Document) -> CGPoint {
        guard let node = document.node(with: id) else { return .zero }
        return point(of: node)
    }

    /// Every card as it's drawn right now, the live translation of a drag included: one pass over
    /// the nodes, so the edges, the rings and the drop test all read the same rectangles instead of
    /// each working them out again.
    private func cardBoxes(in document: Document) -> [UUID: CGRect] {
        var boxes: [UUID: CGRect] = [:]
        boxes.reserveCapacity(document.nodes.count)
        for node in document.nodes { boxes[node.id] = card(around: point(of: node), of: node.id) }
        return boxes
    }

    // MARK: Canvas gestures (pan · hold to record · double-tap)

    /// What the finger on the bare canvas turned out to be doing.
    private enum CanvasPhase { case idle, pressing, panning, selecting, recording }

    private func canvasGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved: CGFloat = hypot(value.translation.width, value.translation.height)
                if gestureStart != value.startLocation {
                    // A new touch. Every one starts out ambiguous: it becomes a pan the moment it
                    // moves, and if it stays put it's a recording — a node under the finger, filling
                    // as you speak. Whatever the canvas was still coasting through, a finger down
                    // stops it.
                    stopGlide()
                    // A box left over from a gesture the system cancelled goes with the new touch.
                    marqueeOrigin = nil
                    marqueeCurrent = nil
                    gestureStart = value.startLocation
                    isSecondTouch = isFollowUpTouch(at: value.startLocation)
                    phase = .pressing
                    lastPanTranslation = value.translation
                    if !pickingOutThisTouch { armHold(at: value.startLocation) }
                } else if phase == .pressing, moved > GraphCanvas.tapSlop {
                    cancelHold()
                    // While selecting — the mode, or ⌘ held as this touch went down — a drag is the
                    // selection box; the rest of the time it's a pan.
                    if pickingOutThisTouch {
                        beginMarquee(at: value.startLocation)
                    } else {
                        phase = .panning
                    }
                }
                switch phase {
                case .panning:
                    // Incremental, so a pinch running alongside can move `pan` too.
                    pan.x += value.translation.width - lastPanTranslation.width
                    pan.y += value.translation.height - lastPanTranslation.height
                case .recording:
                    // The readout follows the finger, so it stays in sight however the hand drifts.
                    recordingAnchor = value.location
                    trackRecordingTouch(at: value.location)
                case .selecting:
                    marqueeCurrent = canvasPoint(for: value.location)
                case .idle, .pressing:
                    break
                }
                lastPanTranslation = value.translation
            }
            .onEnded { value in
                cancelHold()
                let moved: CGFloat = hypot(value.translation.width, value.translation.height)
                switch phase {
                case .recording:
                    finishHoldRecording()
                    resetChain()
                case .selecting:
                    finishMarquee()
                case .idle, .pressing:
                    if moved <= GraphCanvas.tapSlop { registerTap(at: value.startLocation) }
                case .panning:
                    startGlide(velocity: value.velocity)
                }
                // The finger is off the glass: anything Auto tidy put off can happen now.
                flushPendingTidy()
                phase = .idle
                gestureStart = nil
                isSecondTouch = false
                lastPanTranslation = .zero
            }
    }

    /// Pinch to zoom — about the pinch, and without taking the pan with it. The scale is applied a
    /// step at a time against whatever `pan` currently is, so the one-finger drag that keeps
    /// running through a pinch can pan at the same time instead of being overwritten each frame.
    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // A second finger means this touch was never a hold, and never a tap either.
                stopGlide()
                if phase == .pressing {
                    cancelHold()
                    phase = .panning
                }
                let anchor: CGPoint
                if let existing = zoomAnchor {
                    anchor = existing
                } else {
                    anchor = value.startLocation
                    zoomAnchor = anchor
                    lastMagnification = 1
                }
                let step: CGFloat = value.magnification / max(lastMagnification, 0.01)
                lastMagnification = value.magnification
                let next: CGFloat = min(max(scale * step, GraphCanvas.minScale), GraphCanvas.maxScale)
                let factor: CGFloat = next / scale
                pan = CGPoint(x: anchor.x - (anchor.x - pan.x) * factor,
                              y: anchor.y - (anchor.y - pan.y) * factor)
                scale = next
            }
            .onEnded { _ in
                zoomAnchor = nil
                lastMagnification = 1
            }
    }

    /// A view point in canvas coordinates — the inverse of the transform `content` applies.
    ///
    /// Held inside the laid-out canvas, so a node made after an hour of panning in one direction
    /// still has a card that's actually drawn. It takes some sixty screenfuls of dragging to reach,
    /// which is why the canvas reads as endless without being so.
    private func canvasPoint(for viewPoint: CGPoint) -> CGPoint {
        let limit: CGFloat = GraphCanvas.center - 200
        let x: CGFloat = (viewPoint.x - pan.x) / scale
        let y: CGFloat = (viewPoint.y - pan.y) / scale
        return CGPoint(x: min(max(x, -limit), limit), y: min(max(y, -limit), limit))
    }

    // MARK: Hold to record

    /// Hold a finger still anywhere on the canvas and a node appears under it and starts recording —
    /// every time, not only for the first node of a graph and no longer needing a tap in front of it.
    /// The hold *is* the record button here, so it answers the same way wherever it lands.
    private func armHold(at viewPoint: CGPoint) {
        WWHaptics.prepare()          // this press may be a recording in 0.4 seconds
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(GraphCanvas.holdDuration * 1_000_000_000))
            guard !Task.isCancelled, phase == .pressing else { return }
            beginHoldRecording(at: viewPoint)
        }
    }

    /// Whether this touch is the second of a pair: soon enough after the last tap, and close enough
    /// to it. Consumed on the way past, so three taps in a row don't all count as seconds.
    ///
    /// Still recognised on the way *down* even though holding no longer depends on it, because the
    /// answer decides what letting go means: a lone tap puts things away, the second of a pair makes
    /// a node to type into.
    private func isFollowUpTouch(at viewPoint: CGPoint) -> Bool {
        guard let last = lastTap,
              Date().timeIntervalSince(last.at) < GraphCanvas.doubleTapWindow,
              hypot(viewPoint.x - last.point.x, viewPoint.y - last.point.y) < 44
        else { return false }
        lastTap = nil
        return true
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }

    /// The hold has been held: put a node under the finger and start capturing into it.
    private func beginHoldRecording(at viewPoint: CGPoint) {
        guard canRecord() else { return }
        finishEditing()
        menuNodeID = nil

        let spot = canvasPoint(for: viewPoint)
        let node = GraphNode(position: GraphPoint(x: spot.x, y: spot.y))
        do {
            try recorder.start(to: model.documents.newAudioURL().url)
        } catch {
            model.setupError = error.localizedDescription
            return
        }
        model.documents.addNode(node, to: documentID)
        recordingNodeID = node.id
        recordingAnchor = viewPoint
        chainRingCenter = viewPoint
        phase = .recording
        WWHaptics.recordingStarted()
    }

    /// A "+" held rather than tapped: make the node it would have made, and record into it until
    /// the finger lifts — the canvas's hold, at a place in the graph that's already decided.
    private func holdRecord(at spot: CGPoint, _ make: () -> GraphNode?) {
        guard canRecord() else { return }
        finishEditing()
        menuNodeID = nil
        guard let node = make() else { return }
        do {
            try recorder.start(to: model.documents.newAudioURL().url)
        } catch {
            model.setupError = error.localizedDescription
            model.documents.deleteNode(node.id, in: documentID)
            return
        }
        autoTidySiblings(of: node, whenTouchEnds: true)
        recordingNodeID = node.id
        // The "+" is where the finger is, so anchoring to the button anchors to the finger.
        recordingAnchor = viewPoint(for: spot)
        WWHaptics.recordingStarted()
    }

    /// A canvas point in view coordinates — the forward direction of `canvasPoint(for:)`.
    private func viewPoint(for spot: CGPoint) -> CGPoint {
        CGPoint(x: spot.x * scale + pan.x, y: spot.y * scale + pan.y)
    }

    /// Whether capture can start this instant.
    ///
    /// Permission is *checked*, never awaited: by the time a hold is recognised the user is already
    /// holding, so an await here is a beat of silence at the head of every clip — and a promise
    /// from elsewhere that has to come back before anything happens. Asking is a separate path,
    /// taken once, on the first hold of the app's life.
    private func canRecord() -> Bool {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            requestMicrophoneAccess()
            return false
        }
        return true
    }

    private func requestMicrophoneAccess() {
        Task { @MainActor in
            let granted = await recorder.requestPermission()
            if !granted {
                model.setupError = "Microphone permission is required to record."
            }
        }
    }

    /// The finger lifted: stop, file the clip against the node it was spoken into, and transcribe.
    private func finishHoldRecording() {
        guard let nodeID = recordingNodeID else { return }
        recordingNodeID = nil
        recordingAnchor = nil
        guard let result = recorder.stop() else {
            model.documents.deleteNode(nodeID, in: documentID)
            return
        }
        // A hold released the instant it's recognised isn't a recording. Drop the clip and the node
        // it made, rather than leaving an empty card behind for every stray press.
        guard result.duration >= GraphCanvas.minimumClip else {
            try? FileManager.default.removeItem(at: result.url)
            model.documents.deleteNode(nodeID, in: documentID)
            return
        }
        model.captureGraphNode(audioURL: result.url, duration: result.duration,
                               nodeID: nodeID, in: documentID)
    }

    // MARK: Recording in a chain

    /// A ring is drawn round the node being recorded into. Stay inside it and you're still talking
    /// about that node; leave it and the clip is filed, a fresh one starts, and the node it makes
    /// hangs off the one you just finished — so a whole line of thought can be spoken without the
    /// finger ever leaving the glass.
    private func trackRecordingTouch(at point: CGPoint) {
        if chainFollowingNodeID != nil {
            // The new node is still following the finger, waiting for it to stop somewhere.
            chainFollowPoint = canvasPoint(for: point)
            if hypot(point.x - settleReference.x, point.y - settleReference.y) > GraphCanvas.settleSlop {
                settleReference = point
                settleSince = Date()
            }
            return
        }
        guard let ring = chainRingCenter else { return }
        if hypot(point.x - ring.x, point.y - ring.y) > GraphCanvas.chainRadius {
            advanceChain(to: point)
        }
    }

    /// The finger left the ring: file what's been said, and carry straight on into the next node.
    private func advanceChain(to point: CGPoint) {
        guard let previous = recordingNodeID else { return }
        finishHoldRecording()
        guard canRecord() else { return }

        // A clip too short to keep takes its node with it, so check the last one is still there
        // before hanging anything off it.
        let parentID = document?.node(with: previous) != nil ? previous : nil
        let spot = canvasPoint(for: point)
        let node = GraphNode(parentID: parentID, position: GraphPoint(x: spot.x, y: spot.y))
        do {
            try recorder.start(to: model.documents.newAudioURL().url)
        } catch {
            model.setupError = error.localizedDescription
            resetChain()
            return
        }
        model.documents.addNode(node, to: documentID)
        autoTidySiblings(of: node, whenTouchEnds: true)
        recordingNodeID = node.id
        recordingAnchor = point
        chainRingCenter = nil               // no ring until this one has somewhere to be
        chainFollowingNodeID = node.id
        chainFollowPoint = spot
        settleReference = point
        settleSince = Date()
        watchForSettle()
        WWHaptics.recordingStarted()
    }

    /// Watch for the finger to stop. It has to be a clock rather than the gesture: a finger held
    /// perfectly still sends no events at all, which is exactly the case being waited for.
    private func watchForSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            while !Task.isCancelled, chainFollowingNodeID != nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, chainFollowingNodeID != nil else { return }
                if Date().timeIntervalSince(settleSince) >= GraphCanvas.settleDelay {
                    settleChain()
                    return
                }
            }
        }
    }

    /// Settled: leave the node where the finger stopped, put the ring round it, and bring the canvas
    /// across so it's centred — which is also what leaves room to strike out in any direction next.
    private func settleChain() {
        settleTask?.cancel()
        settleTask = nil
        guard let id = chainFollowingNodeID, let spot = chainFollowPoint else { return }
        chainFollowingNodeID = nil
        chainFollowPoint = nil
        model.documents.moveNodes([id: GraphPoint(x: spot.x, y: spot.y)], in: documentID)
        chainRingCenter = recordingAnchor
        center(on: spot)
        haptic()
    }

    private func resetChain() {
        settleTask?.cancel()
        settleTask = nil
        chainRingCenter = nil
        chainFollowingNodeID = nil
        chainFollowPoint = nil
    }

    /// A touch that came and went without moving. The second of a pair — an ordinary double tap —
    /// makes a node to type into, while a lone tap puts away whatever is open and drops the
    /// selection. (Holding rather than tapping is the other thing entirely: a node that records.)
    ///
    /// While selecting, neither tap makes anything: a tap on bare canvas there is "none of these",
    /// which is the one thing a box drawn round the wrong nodes needs.
    private func registerTap(at viewPoint: CGPoint) {
        if isSecondTouch, !pickingOutThisTouch {
            addTypedNode(at: viewPoint)
            return
        }
        lastTap = (Date(), viewPoint)
        finishEditing()
        withAnimation(.snappy(duration: 0.2)) {
            menuNodeID = nil
            // "None of these" — but *not* while picking out. A tap that lands on a card is the
            // card's, and this gesture can see it too; dropping the selection here would undo the
            // card's own toggle a fraction of a second after it happened, which is why picking a
            // second node used to leave only the second node. While ⌘ is engaged the selection is
            // let go by Done, or by the bar, or by letting ⌘ go — never by a tap that might not
            // have been meant for the canvas at all.
            if !pickingOutThisTouch { selectedNodeIDs = [] }
        }
    }

    private func addTypedNode(at viewPoint: CGPoint) {
        let spot = canvasPoint(for: viewPoint)
        let node = GraphNode(position: GraphPoint(x: spot.x, y: spot.y))
        model.documents.addNode(node, to: documentID)
        startEditing(node)
    }

    /// The ring around the node being recorded into: cross it and the next node begins.
    @ViewBuilder
    private func chainRing() -> some View {
        if recordingNodeID != nil, let ring = chainRingCenter {
            Circle()
                .stroke(WW.ember.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 6]))
                .frame(width: GraphCanvas.chainRadius * 2, height: GraphCanvas.chainRadius * 2)
                .position(x: ring.x, y: ring.y)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// The elapsed counter, floating clear of the finger that's holding the canvas (or a "+") down.
    ///
    /// The node itself is under the fingertip while it records — which is right, it's where it
    /// belongs — so the one thing you actually need to watch is put where you can see it, and kept
    /// on screen if the hold wanders towards an edge.
    @ViewBuilder
    private func recordingReadout(in size: CGSize) -> some View {
        if recordingNodeID != nil, let anchor = recordingAnchor {
            let x: CGFloat = min(max(80, anchor.x), max(80, size.width - 80))
            let y: CGFloat = max(34, anchor.y - 62)
            HStack(spacing: 9) {
                Circle()
                    .fill(WW.ember)
                    .frame(width: 10, height: 10)
                Text(Recording.durationLabel(recorder.elapsed))
                    .font(.system(size: 17, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(WW.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(WW.surface, in: Capsule())
            .overlay(Capsule().stroke(WW.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
            .position(x: x, y: y)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: Momentum

    /// Let go mid-pan and the canvas carries on for a moment, shedding speed — the flick you'd
    /// expect from anything else that scrolls.
    ///
    /// Stepped by hand rather than handed to `withAnimation`, because an animation would move
    /// `pan` to its destination immediately and leave the next touch to start from there: you'd
    /// grab the canvas and it would jump. This way the value on screen is the value, and a finger
    /// down simply stops it.
    private func startGlide(velocity: CGSize) {
        stopGlide()
        var vx = velocity.width
        var vy = velocity.height
        guard hypot(vx, vy) > GraphCanvas.glideThreshold else { return }
        glideTask = Task { @MainActor in
            while !Task.isCancelled, hypot(vx, vy) > 24 {
                pan.x += vx / 60
                pan.y += vy / 60
                vx *= GraphCanvas.glideDecay
                vy *= GraphCanvas.glideDecay
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func stopGlide() {
        glideTask?.cancel()
        glideTask = nil
    }

    // MARK: Selecting

    /// Whether ⌘ is engaged as far as what's *drawn* is concerned: the on-screen button held down,
    /// or a hardware ⌘ held. Both are view state, so the cards, the "+" buttons and the quick
    /// actions follow them.
    private var isCommandEngaged: Bool { modifierKeys.commandDown }

    /// The same for ⌥, which on this canvas means "copy what I drag".
    private var isOptionEngaged: Bool { modifierKeys.optionDown }

    /// And ⇧, which means nothing on its own here — it only ever qualifies ⌘, turning "out of the
    /// network" into "out of the ring".
    private var isShiftEngaged: Bool { modifierKeys.shiftDown }

    /// Whether the canvas is in picking-out state: ⌘ engaged, or the mode (⋯ → Select Nodes) that
    /// stays on with nothing held.
    private var isPickingOut: Bool { isSelecting || isCommandEngaged }

    /// The same question at the moment a touch begins, which is where a drag decides whether it's a
    /// selection box or a pan. This one also counts the flags read off the touch itself, which is
    /// how a hardware modifier is known on iOS 17, where nothing publishes a key press.
    private var pickingOutThisTouch: Bool { isPickingOut || keys.isCommandDown }

    /// What a drag beginning this instant means. Read once, as the drag starts — see `dragMode`.
    ///
    /// ⌘ wins over ⌥ if somehow both are down: taking a node out of the network is the destructive
    /// one of the two, and a gesture that might be either should be the one you can see happening.
    /// **⇧ softens ⌘** rather than adding to it — ⌘⇧ takes the card out of its ring and leaves the
    /// tree alone — so the more destructive reading is the one you get by holding *less*.
    private var dragModeForThisTouch: NodeDragMode {
        if isCommandEngaged || keys.isCommandDown {
            return isShiftEngaged || keys.isShiftDown ? .leaveGroup : .unlink
        }
        if isOptionEngaged || keys.isOptionDown { return .copy }
        return .move
    }

    /// A drag on bare canvas while selecting: out comes the box.
    private func beginMarquee(at viewPoint: CGPoint) {
        finishEditing()
        menuNodeID = nil
        quickActionsTask?.cancel()
        hoveringQuickActions = false
        hoveredNodeID = nil
        tappedNodeID = nil
        let spot = canvasPoint(for: viewPoint)
        marqueeOrigin = spot
        marqueeCurrent = spot
        selectedNodeIDs = []
        phase = .selecting
        haptic(strong: true)
    }

    /// The box as it stands, in canvas points, however it was dragged out.
    private var marqueeRect: CGRect? {
        guard let origin = marqueeOrigin, let current = marqueeCurrent else { return nil }
        return CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                      width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    /// Everything the box touched is selected — touched, not swallowed whole, since a card is wide
    /// and a box drawn across a column of them should take the column.
    private func finishMarquee() {
        let box = marqueeRect
        marqueeOrigin = nil
        marqueeCurrent = nil
        guard let box, let document else { return }
        let caught = document.nodes.filter { box.intersects(rect(of: $0, in: document)) }
        withAnimation(.snappy(duration: 0.2)) { selectedNodeIDs = Set(caught.map(\.id)) }
        if !caught.isEmpty { haptic() }
    }

    /// "Select Nodes", from the ⋯ menu: the mode where a drag draws a box and a tap picks a card
    /// out. It exists because the hold doesn't do this any more — the hold makes a node and records
    /// into it, everywhere — so choosing several nodes is something you ask for.
    private func beginSelecting() {
        finishEditing()
        cancelHold()
        withAnimation(.snappy(duration: 0.2)) {
            menuNodeID = nil
            isSelecting = true
        }
    }

    /// "Done": out of the mode, and nothing held.
    private func endSelecting() {
        marqueeOrigin = nil
        marqueeCurrent = nil
        withAnimation(.snappy(duration: 0.2)) {
            isSelecting = false
            selectedNodeIDs = []
        }
    }

    /// A tap on a card while selecting: in, or out.
    private func toggleSelection(of node: GraphNode) {
        withAnimation(.snappy(duration: 0.2)) {
            if selectedNodeIDs.contains(node.id) {
                selectedNodeIDs.remove(node.id)
            } else {
                selectedNodeIDs.insert(node.id)
            }
        }
        haptic()
    }

    // MARK: Lining a selection up

    /// The selected cards as they're actually drawn. Alignment is about *edges*, and a node's
    /// stored position is its centre, so it takes the measured sizes to say where a card's left
    /// side is — which is why the arithmetic is handed boxes rather than nodes.
    private func selectionBoxes(in document: Document) -> [GraphNodeBox] {
        selectedNodeIDs.compactMap { id -> GraphNodeBox? in
            guard document.node(with: id) != nil else { return nil }
            let box = rect(of: id, in: document)
            return GraphNodeBox(id: id,
                                center: GraphPoint(x: Double(box.midX), y: Double(box.midY)),
                                width: Double(box.width), height: Double(box.height))
        }
    }

    /// Run one of the four arrangements over the selection and write the result back — one edit,
    /// the way a drag is one edit. Only the selected nodes move: a branch travels whole when you
    /// drag it, but lining cards up is about the cards you picked out.
    private func arrangeSelection(_ what: String,
                                  _ arrange: ([GraphNodeBox]) -> [UUID: GraphPoint]) {
        guard let document else { return }
        let positions = arrange(selectionBoxes(in: document))
        guard !positions.isEmpty else { return }
        withAnimation(.snappy(duration: 0.25)) {
            model.documents.moveNodes(positions, in: documentID)
        }
        if let settled = self.document {
            updateGroupMembership(after: Set(positions.keys), in: settled)
        }
        haptic()
        wwLog("\(what): moved \(positions.count) graph node\(positions.count == 1 ? "" : "s")", .general)
    }

    /// The nodes a drag should carry: the whole selection when the node under the finger is part of
    /// it, otherwise just that node — with, for a move or a copy, everything hanging off it.
    ///
    /// An **unlink** drag carries the picked nodes alone. Unlinking joins a node's children to its
    /// parent, so the branch stays where it is and goes on making sense; taking the children along
    /// would be the plain drag, which is what you get without ⌘ down. **⌘⇧** isn't an unlink —
    /// the node stays in the tree — so it carries its branch like any other move, and the children
    /// that were in the ring with it come out with it.
    private func draggedBranch(from node: GraphNode, in document: Document,
                               mode: NodeDragMode) -> Set<UUID> {
        let picked: Set<UUID> = selectedNodeIDs.contains(node.id) ? selectedNodeIDs : [node.id]
        guard mode != .unlink else { return picked }
        return Set(picked.flatMap { document.subtree(of: $0) })
    }

    /// Delete what's picked out — the selection bar's trash, and the **Delete key**, which is the
    /// same thing said with a keyboard. Nothing selected is nothing to delete: the key does nothing
    /// rather than guessing at what you meant.
    private func deleteSelection() {
        let ids = selectedNodeIDs
        guard !ids.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) {
            selectedNodeIDs = []
            for id in ids { model.documents.deleteNode(id, in: documentID) }
        }
        haptic()
        wwLog("Deleted \(ids.count) graph node\(ids.count == 1 ? "" : "s")", .general)
    }

    private func haptic(strong: Bool = false) {
        if strong { WWHaptics.medium() } else { WWHaptics.light() }
    }

    // MARK: Dragging a node (and its branch)

    /// Dragging a node reads its translation in the **global** space, not the node's own.
    ///
    /// A `DragGesture` measures against the coordinate space of the view it's attached to — and
    /// this one moves that view. Each frame the card would be redrawn under the finger, the next
    /// event measured from the card's new home, and the translation come back halved: the node
    /// flickered between the finger and half way there, and never quite arrived over the node you
    /// were trying to drop it on. The global space doesn't move, so the translation is the honest
    /// distance the finger has travelled; dividing by `scale` puts it in canvas points.
    private func nodeDrag(_ node: GraphNode, in document: Document) -> some Gesture {
        // Four points, not six: the card is under the finger and should leave with it. The whole
        // threshold is also the distance the card jumps when the drag does begin — the translation
        // arrives already accumulated — so a smaller one is a smaller lurch as well. It stays above
        // the long press's `maximumDistance` (3), so the two can't both be waiting on each other,
        // and comfortably above the drift of a double tap.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragSourceID != node.id { beginDrag(of: node, in: document) }
                // Translations arrive in view points; the canvas is in canvas points.
                dragTranslation = CGSize(width: value.translation.width / scale,
                                         height: value.translation.height / scale)
                // Re-parenting is a plain drag's business, and a single-node idea at that: a whole
                // selection dropped on one node has no one answer, and a node being pulled *out* of
                // the network (or a copy pulled out of a node) shouldn't land back in it.
                dropTargetID = dragMode == .move && !isMultiDrag
                    ? dropTarget(for: node, in: document)
                    : nil          // ⌘, ⌘⇧ and ⌥ are all "take this out of something", not "put it in"
            }
            .onEnded { _ in
                let mode = dragMode
                let dragged = draggingNodeID
                let target = dropTargetID
                let branch = draggingBranch
                let translation = dragTranslation
                draggingNodeID = nil
                dragSourceID = nil
                draggingBranch = []
                dragTranslation = .zero
                dropTargetID = nil
                dragMode = .move

                // The unlinking a ⌘ drag does happened as the drag *began* — see `beginDrag` —
                // so by here the card has been out of the network the whole way across the canvas.

                guard let latest = self.document else { return }
                commit(branch: branch, movedBy: translation, in: latest)
                if mode == .copy {
                    wwLog("Copied \(branch.count) graph node\(branch.count == 1 ? "" : "s")",
                          .general)
                }
                // Groups first, judged **where the finger let go** — which is what the ring was
                // showing you the whole way across (`liveMembers`), so the drop confirms it. What
                // an attach does next is the layout's answer to a re-parenting, not a second
                // opinion about who's in the group: a card that joined stays joined, and its new
                // ring simply stretches to reach wherever the branch settles.
                if let settled = self.document {
                    updateGroupMembership(after: branch, in: settled, leaving: mode.leavesGroups)
                }
                if mode == .move, let dragged, let target,
                   model.documents.attachNode(dragged, to: target, in: documentID,
                                              heights: measuredHeights) {
                    let name = latest.node(with: target)?.trimmedText ?? ""
                    wwLog("Hung a graph branch under “\(name.isEmpty ? "a node" : name)”", .general)
                    haptic()
                    // With Auto tidy on, a branch hung off a node lines that node's children up
                    // around it — the same tidy adding a child runs, for the same reason: the row
                    // just changed, and the new arrival is what changed it.
                    autoTidyChildren(of: target)
                }
            }
    }

    /// The first frame of a node drag: work out what the drag *is* — a move, a node pulled out of
    /// the network (⌘), or a copy pulled out of one (⌥) — and set up what it carries.
    ///
    /// A copy is made here rather than when the finger lifts, so the thing you're dragging is on
    /// screen from the first frame: the copies appear over their originals and travel with the
    /// touch, which is what makes the gesture read as pulling a duplicate out.
    private func beginDrag(of node: GraphNode, in document: Document) {
        finishEditing()
        menuNodeID = nil
        dragSourceID = node.id
        dragTranslation = .zero
        dragMode = dragModeForThisTouch

        let picked = draggedBranch(from: node, in: document, mode: dragMode)
        guard dragMode == .copy else {
            draggingNodeID = node.id
            draggingBranch = picked
            // A ⌘ drag comes away from the network **as it starts**, not when it stops: the card
            // has to be seen leaving, its parent and children joined up behind it, while the finger
            // is still moving. Doing it on release meant a whole drag that looked like an ordinary
            // move and only turned out to be a detachment once it was over.
            //
            // ⌘⇧ has nothing to do up front — a group is left by being carried out of the ring, and
            // the ring shows that happening — so it only announces itself.
            if dragMode == .unlink { unlink(picked) }
            if dragMode == .leaveGroup { haptic(strong: true) }
            return
        }

        // Nothing copied (a node that vanished under the finger) falls back to an ordinary move
        // rather than dragging thin air.
        let copies = model.documents.duplicateNodes(picked, in: documentID)
        draggingNodeID = copies[node.id] ?? node.id
        draggingBranch = copies.isEmpty ? picked : Set(copies.values)
        if copies.isEmpty {
            dragMode = .move
        } else {
            haptic(strong: true)
        }
    }

    /// Write a dragged branch's new positions back — one edit at the end of the drag rather than
    /// one per frame of it.
    private func commit(branch: Set<UUID>, movedBy translation: CGSize, in document: Document) {
        guard translation != .zero else { return }
        var positions: [UUID: GraphPoint] = [:]
        for id in branch {
            guard let node = document.node(with: id) else { continue }
            positions[id] = GraphPoint(x: node.position.x + translation.width,
                                       y: node.position.y + translation.height)
        }
        model.documents.moveNodes(positions, in: documentID)
    }

    /// Whether the drag in progress is carrying more than one selected branch.
    private var isMultiDrag: Bool {
        guard let id = draggingNodeID else { return false }
        return selectedNodeIDs.count > 1 && selectedNodeIDs.contains(id)
    }

    /// The node a drop would land on: whichever card the dragged node's centre is over, ignoring
    /// the branch being dragged (a node can't hang off itself, or off its own child).
    private func dropTarget(for node: GraphNode, in document: Document) -> UUID? {
        let center = point(of: node)
        let excluded = draggingBranch
        return document.nodes.first(where: { other in
            guard !excluded.contains(other.id) else { return false }
            // A little generous around the edges: you're aiming a card with your fingertip, and the
            // card is what you can see — the centre landing *near* the target should count.
            return rect(of: other, in: document).insetBy(dx: -14, dy: -14).contains(center)
        })?.id
    }

    /// A node's card in canvas points: where it is now, at the size it actually measured.
    private func rect(of id: UUID, in document: Document) -> CGRect {
        card(around: point(of: id, in: document), of: id)
    }

    private func rect(of node: GraphNode, in document: Document) -> CGRect {
        card(around: point(of: node), of: node.id)
    }

    /// A card of the measured size, centred on `center` — the standard card where the canvas hasn't
    /// measured that one yet.
    private func card(around center: CGPoint, of id: UUID) -> CGRect {
        let size = nodeSizes[id] ?? GraphCanvas.assumedCardSize
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Adding nodes from the "+" buttons

    private func addChild(to parent: GraphNode) {
        guard let node = model.documents.addChildNode(to: parent.id, in: documentID) else { return }
        autoTidySiblings(of: node)
        startEditing(node)
    }

    private func insertNode(on edge: GraphEdgeLine) {
        guard let node = model.documents.insertNode(between: edge.parentID, and: edge.id,
                                                    in: documentID) else { return }
        autoTidySiblings(of: node)
        startEditing(node)
    }

    // MARK: Editing a node in place

    private func startEditing(_ node: GraphNode) {
        if editingNodeID != nil { finishEditing() }
        menuNodeID = nil
        let text = node.trimmedText
        editingText = text
        editingSelection = NSRange(location: (text as NSString).length, length: 0)
        withAnimation(.snappy(duration: 0.22)) { editingNodeID = node.id }
    }

    /// Done: write the buffer back. A node left with nothing in it — typed into and abandoned — is
    /// removed rather than left on the canvas as a blank card; one that's waiting on a recording, or
    /// holding a branch up, stays.
    private func finishEditing() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        model.documents.setNodeText(id, in: documentID, to: editingText)
        guard let document, let node = document.node(with: id) else { return }
        if !node.hasText, node.recordingID == nil, document.children(of: id).isEmpty {
            model.documents.deleteNode(id, in: documentID)
            // Auto tidy made room for it when it appeared; the row closes back up now it's gone.
            autoTidySiblings(of: node)
        }
    }

    /// "Revise" from inside the editor: keep what's typed, then record a clip that replaces it.
    private func reviseEditingNode() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        model.documents.setNodeText(id, in: documentID, to: editingText)
        reviseTask = ReviseTask(nodeID: id)
    }

    /// "Delete" from inside the editor: the node goes, and the editor closes with it. What was
    /// typed is dropped rather than written back — the node is what you asked to be rid of — and its
    /// children are promoted to its parent the way every other delete on this canvas does, so the
    /// branch below survives.
    private func deleteEditingNode() {
        guard let id = editingNodeID else { return }
        let node = document?.node(with: id)
        editingNodeID = nil
        model.documents.deleteNode(id, in: documentID)
        autoTidySiblings(of: node)
        haptic()
        wwLog("Deleted a graph node", .general)
    }

    /// "Transform" from inside the editor: flush what's on screen, then pick a preset to run on it.
    private func transformEditingNode() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        model.documents.setNodeText(id, in: documentID, to: editingText)
        transformTargetID = id
    }

    /// Take nodes out of the tree without taking their words with them: each one's parent and
    /// children are joined to each other, so the branch survives, and the node floats free where it
    /// stands.
    ///
    /// This is what **⌘ + drag** does — you pull a card out of the network and it comes out, which
    /// is the gesture the old scissors button was standing in for. Nodes that weren't joined to
    /// anything are left alone: a loose card dragged with ⌘ down is simply a card being moved.
    ///
    /// It runs as the drag **begins** (`beginDrag`), not when it ends: the card comes away under
    /// your finger, and what you watch happen is what happened.
    private func unlink(_ ids: Set<UUID>) {
        guard let document else { return }
        let linked = ids.filter { id in
            guard let node = document.node(with: id) else { return false }
            return node.parentID != nil || !document.children(of: id).isEmpty
        }
        guard !linked.isEmpty else { return }
        for id in linked { model.documents.unlinkNode(id, in: documentID) }
        // The firmer of the two taps: this is the drag announcing what it is, at the moment it
        // becomes it, rather than a small confirmation after the fact.
        haptic(strong: true)
        wwLog("Unlinked \(linked.count) graph node\(linked.count == 1 ? "" : "s")", .general)
    }

    /// "Tidy children": line this node's children up beside it, evenly spaced, each with its own
    /// branch in tow. The one bit of arrangement the canvas does for you, and only when asked.
    private func tidyChildren(of node: GraphNode) {
        model.documents.tidyChildren(of: node.id, in: documentID, heights: measuredHeights)
        haptic()
        wwLog("Tidied the children of a graph node", .general)
    }

    /// Auto tidy: line a node's siblings up around it — the same tidy its own menu offers, run
    /// without being asked, whenever the row it belongs to has just changed (a node added to it, or
    /// an empty one abandoned out of it).
    ///
    /// Only a node with a parent has siblings to line up, so a root — a hold on bare canvas, a
    /// double-tap, a clip moved in from the Inbox — is left exactly where it was put. A node made
    /// mid-gesture (a "+" held down, a chain still growing) has its tidy **held until the finger
    /// lifts**: the card is what's recording, and it must not slide out from under the touch
    /// filling it.
    private func autoTidySiblings(of node: GraphNode?, whenTouchEnds: Bool = false) {
        guard autoTidy, let parentID = node?.parentID else { return }
        if whenTouchEnds {
            pendingTidyParents.insert(parentID)
        } else {
            withAnimation(.snappy(duration: 0.25)) {
                model.documents.tidyChildren(of: parentID, in: documentID, heights: measuredHeights)
            }
        }
    }

    /// Auto tidy, asked of one parent by id: what a branch *dropped onto* a node owes its new
    /// siblings. `autoTidySiblings` above answers the same question for a node that was just made;
    /// this one is for a node that has just arrived from somewhere else on the canvas.
    private func autoTidyChildren(of parentID: UUID) {
        guard autoTidy else { return }
        withAnimation(.snappy(duration: 0.25)) {
            model.documents.tidyChildren(of: parentID, in: documentID, heights: measuredHeights)
        }
    }

    /// Run the tidies a gesture put off. Parents are taken in the order the graph stores them —
    /// which is the order they were made — so a chain spoken in one breath lines up from the top
    /// down, each tidy moving whole branches that the next one then arranges.
    private func flushPendingTidy() {
        guard !pendingTidyParents.isEmpty else { return }
        let pending = pendingTidyParents
        pendingTidyParents = []
        guard let document else { return }
        let heights = measuredHeights
        withAnimation(.snappy(duration: 0.25)) {
            for node in document.nodes where pending.contains(node.id) {
                model.documents.tidyChildren(of: node.id, in: documentID, heights: heights)
            }
        }
    }

    private func runTransform(_ preset: PromptPreset, nodeID: UUID) {
        transformingNodeIDs.insert(nodeID)
        Task {
            await model.transformGraphNode(preset, nodeID: nodeID, in: documentID)
            transformingNodeIDs.remove(nodeID)
        }
    }

    // MARK: The long-press dropdown

    private func openMenu(for node: GraphNode) {
        finishEditing()
        haptic()
        withAnimation(.snappy(duration: 0.2)) { menuNodeID = node.id }
    }

    /// The actions a paragraph gets from a swipe, as a list under the node they apply to — there's
    /// no row to swipe on a canvas, so the long press opens them here instead.
    private func menuItems(for node: GraphNode, in document: Document) -> [NodeMenuItem] {
        var items: [NodeMenuItem] = [
            NodeMenuItem(title: "Edit", icon: "pencil") { startEditing(node) },
            NodeMenuItem(title: "Add Child", icon: "plus") { addChild(to: node) },
            NodeMenuItem(title: "Revise", icon: "mic.fill") {
                menuNodeID = nil
                reviseTask = ReviseTask(nodeID: node.id)
            },
            NodeMenuItem(title: "Transform", icon: "wand.and.stars", enabled: model.modelReady) {
                menuNodeID = nil
                transformTargetID = node.id
            },
            NodeMenuItem(title: "Delete", icon: "trash", isDestructive: true) {
                menuNodeID = nil
                model.documents.deleteNode(node.id, in: documentID)
            }
        ]
        if !document.children(of: node.id).isEmpty {
            let tidy = NodeMenuItem(title: "Tidy Children", icon: "rectangle.3.group") {
                menuNodeID = nil
                tidyChildren(of: node)
            }
            items.insert(tidy, at: 2)
        }
        return items
    }

    /// The two things worth doing to one node while ⌘ is engaged, floating just above its card:
    /// **delete it**, and **tidy its children**.
    ///
    /// It's there because ⌘ is: with a pointer, pointing at a card is enough; with a finger, a tap
    /// brings it up (and takes the card in or out of the selection at the same time, which is what a
    /// tap already did). Two actions, not a menu — the long press already opens the full list, and
    /// the point of this one is that it's *there* while your other hand holds the key.
    ///
    /// It acts on the card it's attached to, never on the selection: the selection bar along the
    /// bottom is where "all of these" lives, and a control this close to one card should mean that
    /// card.
    @ViewBuilder
    private func quickActions(for document: Document, in size: CGSize) -> some View {
        // Two or more picked out and this stands down: the bar along the bottom is what a *set* of
        // nodes is worked with, and a control hovering over one of them would be offering to do
        // something to that one alone in the middle of choosing several.
        if isPickingOut, selectedNodeIDs.count < 2,
           let id = quickActionNodeID, let node = document.node(with: id) {
            let center = point(of: node)
            let card = (nodeSizes[id] ?? GraphCanvas.assumedCardSize).height * scale
            let view = CGPoint(x: center.x * scale + pan.x, y: center.y * scale + pan.y)
            let width: CGFloat = 92
            HStack(spacing: 2) {
                quickAction("Delete", "trash", tint: WW.ember) {
                    withAnimation(.snappy(duration: 0.2)) {
                        hoveredNodeID = nil
                        tappedNodeID = nil
                        hoveringQuickActions = false
                        selectedNodeIDs.remove(id)
                        model.documents.deleteNode(id, in: documentID)
                    }
                    autoTidySiblings(of: node)
                    haptic()
                    wwLog("Deleted a graph node", .general)
                }
                quickAction("Tidy Children", "rectangle.3.group", tint: WW.moss,
                            enabled: !document.children(of: id).isEmpty) {
                    withAnimation(.snappy(duration: 0.25)) { tidyChildren(of: node) }
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 34)
            .background(WW.surface.opacity(0.96), in: Capsule())
            .overlay(Capsule().stroke(WW.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            // Pointing at the bar counts as pointing at the card: it's the whole reason the bar is
            // there, and the pointer has to leave the card to reach it.
            .onHover { inside in
                hoveringQuickActions = inside
                if inside {
                    quickActionsTask?.cancel()
                    quickActionsTask = nil
                } else {
                    releaseQuickActions(of: nil)
                }
            }
            .offset(x: min(max(view.x - width / 2, 8), max(size.width - width - 8, 8)),
                    y: max(view.y - card / 2 - GraphCanvas.quickActionsLift, 8))
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            .allowsHitTesting(true)
        }
    }

    /// The pointer has come to rest on a card: raise its quick actions, and call off any clock that
    /// was about to put another card's away.
    private func pointAt(_ id: UUID) {
        quickActionsTask?.cancel()
        quickActionsTask = nil
        // On a card is not on the bar. Said here as well as in the bar's own `onHover`, because a
        // bar that's *removed* from under the pointer (a second card picked out, its node deleted)
        // never sends the "left" event — and a flag stuck on would hold the actions up for good.
        hoveringQuickActions = false
        guard hoveredNodeID != id else { return }
        withAnimation(.snappy(duration: 0.15)) { hoveredNodeID = id }
    }

    /// The pointer has left a card (`id`), or the bar floating above it (`nil`).
    ///
    /// Neither lets go straight away. The bar sits clear of the card, so reaching it means crossing
    /// a few points where the pointer is on neither — and letting go there took the buttons out from
    /// under the pointer on its way to them, which is a bar you can see and never press. So the
    /// hover is held for a moment, and anything the pointer lands on in that moment (the bar, the
    /// same card, the next one) calls the clock off.
    private func releaseQuickActions(of id: UUID?) {
        // Already moved on to another card — that card's own hover has taken over.
        if let id, hoveredNodeID != id { return }
        quickActionsTask?.cancel()
        quickActionsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(GraphCanvas.quickActionsGrace * 1_000_000_000))
            guard !Task.isCancelled, !hoveringQuickActions else { return }
            withAnimation(.snappy(duration: 0.15)) { hoveredNodeID = nil }
        }
    }

    private func quickAction(_ title: String, _ icon: String, tint: Color, enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func menuOverlay(for document: Document, in size: CGSize) -> some View {
        if let id = menuNodeID, let node = document.node(with: id) {
            let items = menuItems(for: node, in: document)
            let height = CGFloat(items.count) * 44 + 8
            let origin = menuOrigin(for: node, in: document, size: size, height: height)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy(duration: 0.2)) { menuNodeID = nil } }
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { item.action() }
                        } label: {
                            Label(item.title, systemImage: item.icon)
                                .font(.callout)
                                .foregroundStyle(item.isDestructive ? WW.ember : WW.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.enabled)
                        .opacity(item.enabled ? 1 : 0.35)
                        if item.id != items.last?.id { WWHairline().padding(.leading, 16) }
                    }
                }
                .padding(.vertical, 4)
                .frame(width: GraphCanvas.menuWidth)
                .background(WW.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(WW.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                .offset(x: origin.x, y: origin.y)
            }
            .transition(.opacity)
        }
    }

    /// Under the node it belongs to, nudged back onto the screen when that would hang it off an edge.
    private func menuOrigin(for node: GraphNode, in document: Document,
                            size: CGSize, height: CGFloat) -> CGPoint {
        let center = point(of: node)
        let view = CGPoint(x: center.x * scale + pan.x, y: center.y * scale + pan.y)
        let cardHeight: CGFloat = (nodeSizes[node.id]?.height
                                    ?? GraphCanvas.assumedCardSize.height) * scale
        let margin: CGFloat = 12
        let maxX: CGFloat = max(margin, size.width - GraphCanvas.menuWidth - margin)
        let maxY: CGFloat = max(margin, size.height - height - margin)
        let x: CGFloat = view.x - GraphCanvas.menuWidth / 2
        let y: CGFloat = view.y + cardHeight / 2 + 10
        return CGPoint(x: min(max(margin, x), maxX), y: min(max(margin, y), maxY))
    }

    // MARK: Groups

    /// The ring round a group: the union of its members' cards, with air around it. Drawn from the
    /// same pass of card rectangles the nodes and edges are, so while a ring is being dragged it
    /// moves in step with what's inside it rather than a frame behind.
    private func boundingBox(of ids: Set<UUID>, boxes: [UUID: CGRect]) -> CGRect? {
        let members = ids.compactMap { boxes[$0] }
        guard var box = members.first else { return nil }
        for other in members.dropFirst() { box = box.union(other) }
        return box.insetBy(dx: -GraphCanvas.groupPadding, dy: -GraphCanvas.groupPadding)
    }

    /// Every ring the canvas is about to draw: the rectangle for each, and the order to draw them
    /// in. One pass for the lot, because a **nested** ring changes the one around it.
    ///
    /// A group whose members are all inside another group's is drawn inside it, and two rings that
    /// happen to be measured from the same outermost cards would land exactly on top of each other.
    /// So the rings are worked out innermost first, and each one is pushed out to clear every ring
    /// nested inside it by `nestedGroupGap` — the ring you can see between two rings.
    ///
    /// Membership itself is untouched by this nesting gap: a node dragged into a ring is judged
    /// against the plain bounding box of the members that didn't move — `liveMembers` while the
    /// drag runs, `boundingBox(ofMembers:in:)` when it ends, and the same test either way — so a
    /// buffer drawn for the eye can't quietly change what a group contains.
    private func groupRings(in document: Document,
                            boxes: [UUID: CGRect]) -> (order: [GraphGroup], frames: [UUID: CGRect]) {
        // Fewest members first: a ring is only ever pushed out by rings already worked out. The
        // member sets are built once here rather than per comparison — this runs on every frame of
        // a drag.
        let inward = document.groups
            .map { (group: $0, members: liveMembers(of: $0, boxes: boxes)) }
            .sorted { $0.members.count < $1.members.count }
        var frames: [UUID: CGRect] = [:]
        for entry in inward {
            guard var frame = boundingBox(of: entry.members, boxes: boxes) else { continue }
            for other in inward where other.group.id != entry.group.id {
                guard let inner = frames[other.group.id],
                      other.members.isStrictSubset(of: entry.members) else { continue }
                frame = frame.union(inner.insetBy(dx: -GraphCanvas.nestedGroupGap,
                                                  dy: -GraphCanvas.nestedGroupGap))
            }
            frames[entry.group.id] = frame
        }
        // Widest first for drawing, so an inner ring's edge and label sit on top of the outer one's.
        return (inward.reversed().map { $0.group }, frames)
    }

    /// Who a ring should be drawn around *right now*, mid-drag — the group's members, plus
    /// whatever is being dragged and currently sits inside it.
    ///
    /// The ring has to answer the drag as it happens: a card carried into a group makes the ring
    /// stretch to take it in, so letting go is a confirmation of what you're already looking at
    /// rather than a surprise. It's the same test `updateGroupMembership` runs on release — the
    /// ring measured from the members that *aren't* moving, and a card counted in when its middle
    /// falls inside it — so what the drag shows is what the drop does.
    ///
    /// Nothing while a **ring** is the thing being dragged (a group moving doesn't change who's in
    /// it), and a **⌘** drag is shown leaving: that's the one gesture that takes a node out.
    private func liveMembers(of group: GraphGroup, boxes: [UUID: CGRect]) -> Set<UUID> {
        guard !draggingBranch.isEmpty, draggingGroupID == nil else { return group.members }
        let settled = group.members.subtracting(draggingBranch)
        guard let frame = boundingBox(of: settled, boxes: boxes) else { return group.members }
        var members = dragMode.leavesGroups ? settled : group.members
        for id in draggingBranch {
            guard let box = boxes[id],
                  frame.contains(CGPoint(x: box.midX, y: box.midY)) else { continue }
            members.insert(id)
        }
        return members
    }

    /// The same, for the places outside the drawing pass that have a document but no prepared
    /// boxes — deciding what a drop left inside a ring, once the move is committed.
    private func boundingBox(ofMembers ids: Set<UUID>, in document: Document) -> CGRect? {
        var boxes: [UUID: CGRect] = [:]
        for id in ids where document.node(with: id) != nil { boxes[id] = rect(of: id, in: document) }
        return boundingBox(of: ids, boxes: boxes)
    }

    /// A dashed ring with a label at its corner. Only the *edge* takes touches — four strips just
    /// inside it — so everything within stays as reachable as it was before the ring was drawn.
    ///
    /// The drag lives on those four strips rather than on the ring as a whole. The ring's own body
    /// is deaf (`allowsHitTesting(false)`, so it isn't a dead zone over every node inside it), and a
    /// gesture on a view whose content takes no touches is a gesture that never starts — which is
    /// why dragging a ring did nothing until the finger came off.
    @ViewBuilder
    private func groupView(_ group: GraphGroup, frame: CGRect) -> some View {
        let grab = GraphCanvas.groupBorderGrab
        let ink = WW.paletteColor(group.colorID) ?? WW.moss
        Color.clear
            .frame(width: frame.width, height: frame.height)
            // A `Color` takes touches across its whole area, which would put a dead zone over every
            // node inside the ring. The body of the ring is deaf; the strips added after it aren't.
            .allowsHitTesting(false)
            // The wash inside the ring, drawn under the cards rather than over them (rings are laid
            // down before the nodes) — and deaf, like the ring itself.
            //
            // Present only while there *is* a colour, rather than always there at zero opacity:
            // "no colour" has to take the wash away, and a view that comes and goes is the one
            // thing SwiftUI can't leave behind.
            .background {
                if let wash = WW.paletteColor(group.colorID) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(wash.opacity(GraphCanvas.tintOpacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // The edge is the group's only handle, so it says when it's under the pointer: the
                // dashes draw together into a solid line and the ink comes up, the same brightness
                // a drag gets. Held, rather than a step between two states, because the pointer is
                // *on* the thing it would move — and the ring being drawn solid is the difference
                // between "a ring round these cards" and "a ring you can take hold of".
                let active = draggingGroupID == group.id || hoveredGroupID == group.id
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(ink.opacity(active ? 0.9 : 0.5),
                            style: StrokeStyle(lineWidth: active ? 2.5 : 1.5,
                                               dash: active ? [] : [8, 6]))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) { grabStrip(group, width: frame.width, height: grab) }
            .overlay(alignment: .bottom) { grabStrip(group, width: frame.width, height: grab) }
            .overlay(alignment: .leading) { grabStrip(group, width: grab, height: frame.height) }
            .overlay(alignment: .trailing) { grabStrip(group, width: grab, height: frame.height) }
            .overlay(alignment: .topLeading) {
                // Straddling the ring's top edge: half the chip's own height above the line.
                groupLabel(group).offset(x: 12, y: -15)
            }
            .position(x: frame.midX + GraphCanvas.center, y: frame.midY + GraphCanvas.center)
            .zIndex(0)
    }

    /// One side of the ring's edge: what you actually take hold of to move a group.
    ///
    /// All four strips report the same hover, so the whole ring lights rather than the side the
    /// pointer happens to be on — you're taking hold of the group, not of its left edge. A pointer
    /// crossing from one strip to the next would otherwise flicker the ring off and on.
    private func grabStrip(_ group: GraphGroup, width: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.snappy(duration: 0.15)) {
                    if inside {
                        hoveredGroupID = group.id
                    } else if hoveredGroupID == group.id {
                        hoveredGroupID = nil
                    }
                }
            }
            .gesture(groupDrag(group))
    }

    /// The name at the ring's top-left corner — tap it to write one, or to let the group go — with
    /// the group's colour dot in front of it, which is where a colour belongs: at the head of the
    /// thing it colours, the same as a node's edit bar.
    private func groupLabel(_ group: GraphGroup) -> some View {
        HStack(spacing: 0) {
            GraphColorDot(colorID: group.colorID, diameter: 11) { colorID in
                model.documents.setGroupColor(group.id, in: documentID, to: colorID)
            }
            .padding(.leading, -3)          // the dot brings its own tap target; close the gap up
            Button {
                groupLabelText = group.label
                labelingGroupID = group.id
            } label: {
                Text(group.hasLabel ? group.trimmedLabel : "Label")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(group.hasLabel ? WW.ink : WW.inkTertiary)
                    .lineLimit(1)
                    .padding(.trailing, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(WW.surface, in: Capsule())
        .overlay(Capsule().stroke(WW.paletteColor(group.colorID) ?? WW.hairline, lineWidth: 1))
    }

    /// Dragging the ring moves what's inside it — and everything hanging off it. A child follows
    /// its parent whoever picked the parent up: dragging a card carries its branch, and so does
    /// dragging a ring the card happens to be in. (A child that's *also* a member is carried once;
    /// the branch is a set.)
    ///
    /// With **⌥ held** it drags a copy instead: the members are duplicated and a fresh ring, same
    /// name and same ink, is drawn round the copies — so a cluster you've arranged once can be
    /// pulled out again as a cluster. (⌘ means nothing here: a ring isn't part of the tree, so
    /// there's nothing to unlink it from.)
    private func groupDrag(_ group: GraphGroup) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if draggingGroupID != group.id { beginDrag(of: group) }
                dragTranslation = CGSize(width: value.translation.width / scale,
                                         height: value.translation.height / scale)
            }
            .onEnded { _ in
                let members = draggingBranch
                let translation = dragTranslation
                let mode = dragMode
                draggingGroupID = nil
                draggingBranch = []
                dragTranslation = .zero
                dragMode = .move
                if let latest = self.document {
                    commit(branch: members, movedBy: translation, in: latest)
                    if mode == .copy {
                        wwLog("Copied a group of \(members.count) graph nodes", .general)
                    }
                }
            }
    }

    /// The first frame of a ring drag — see `beginDrag(of:in:)`, which does the same job for a card.
    private func beginDrag(of group: GraphGroup) {
        finishEditing()
        menuNodeID = nil
        draggingGroupID = group.id
        dragTranslation = .zero
        dragMode = isOptionEngaged || keys.isOptionDown ? .copy : .move

        guard dragMode == .copy else {
            // The members *and their branches*: a child hanging off a member but outside the ring
            // still moves with its parent, exactly as it does when the parent is dragged by itself.
            draggingBranch = document.map { doc in
                Set(group.members.flatMap { doc.subtree(of: $0) })
            } ?? group.members
            return
        }
        let copies = model.documents.duplicateGroup(group.id, in: documentID)
        draggingBranch = copies.isEmpty ? group.members : Set(copies.values)
        if copies.isEmpty {
            dragMode = .move
        } else {
            haptic(strong: true)
        }
    }

    /// Membership is a matter of where things are, but only ever in one direction: a node whose
    /// card comes to rest inside a ring **joins** that group, and nothing an ordinary drag does
    /// takes a node back out of one.
    ///
    /// Joining had to be one-way to be usable at all. Membership was recomputed from position
    /// alone, which meant the group a node had just been dropped into let go of it again the
    /// moment anything moved it — a drop landing on a card, which re-settles the branch beside its
    /// new parent, or a parent dragged elsewhere taking its children along. Worse, a ring measured
    /// from the members that *stayed* could be left with one node and dissolve itself: A over
    /// B, C, D, with B, C, D also inside a wider ring around E — move A and B, C, D go with it,
    /// the wider ring is measured from E alone, and a group nobody touched disappears.
    ///
    /// So **leaving is asked for**: ⌘ + drag, which already means "take this out of the network",
    /// also takes it out of any ring it's dragged clear of (`leaving`). That's the one gesture
    /// that removes, and it's the same one for both kinds of belonging.
    ///
    /// The ring is measured from the members that *didn't* move, so a node can't keep itself in by
    /// its own presence — and a group whose members all moved is left alone entirely: the whole
    /// cluster travelled, which says nothing about who's in it.
    private func updateGroupMembership(after moved: Set<UUID>, in document: Document,
                                       leaving: Bool = false) {
        for group in document.groups {
            let frame = boundingBox(ofMembers: group.members.subtracting(moved), in: document)
            var members = group.members
            for id in moved {
                guard document.node(with: id) != nil else { continue }
                let box = rect(of: id, in: document)
                let inside = frame?.contains(CGPoint(x: box.midX, y: box.midY)) ?? false
                if inside {
                    members.insert(id)
                } else if leaving {
                    members.remove(id)
                }
            }
            guard members != group.members else { continue }
            model.documents.setGroupMembers(group.id, in: documentID, to: members)
        }
    }

    /// The group modal: what a ring is called, and what colour it is. The same sheet whether the
    /// ring has just been drawn (**Group** in the selection bar, which opens it straight away) or is
    /// being renamed (tapping its name at the corner).
    ///
    /// It's a sheet rather than the alert it used to be for one reason: an alert holds a text field
    /// and buttons and nothing else, and a colour is a row of dots. The colour applies as it's
    /// picked — the ring changes behind the sheet — while the name waits for **Save**, which is the
    /// honest difference between a thing you're still typing and a thing you chose.
    @ViewBuilder
    private func groupSheet() -> some View {
        if let id = labelingGroupID, let group = document?.groups.first(where: { $0.id == id }) {
            NavigationStack {
                Form {
                    Section {
                        // Return saves and closes, the way the alert's Save did.
                        TextField("Label", text: $groupLabelText)
                            .submitLabel(.done)
                            .onSubmit { saveGroupLabel(id) }
                    } header: {
                        WWSectionHeader("Name")
                    }
                    .listRowBackground(WW.surface)

                    Section {
                        GraphColorRow(colorID: group.colorID) { picked in
                            model.documents.setGroupColor(id, in: documentID, to: picked)
                            haptic()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    } header: {
                        WWSectionHeader("Colour")
                    } footer: {
                        WWFooter("The ring's own line, and a wash of the same colour behind what's inside it.")
                    }
                    .listRowBackground(WW.surface)

                    Section {
                        Button(role: .destructive) {
                            model.documents.removeGroup(id, in: documentID)
                            labelingGroupID = nil
                            wwLog("Ungrouped graph nodes", .general)
                        } label: {
                            Label("Ungroup", systemImage: "square.dashed")
                                .foregroundStyle(WW.ember)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(WW.surface)
                }
                .wwForm()
                .navigationTitle("Group")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { labelingGroupID = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveGroupLabel(id) }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Write the name back and close the sheet. The colour is already saved — it applies as it's
    /// picked — so this is only ever about the label.
    private func saveGroupLabel(_ groupID: UUID) {
        model.documents.setGroupLabel(groupID, in: documentID, to: groupLabelText)
        labelingGroupID = nil
    }

    /// "Group" in the selection bar: ring the selection, then offer to name it straight away.
    private func groupSelection() {
        guard let group = model.documents.addGroup(members: selectedNodeIDs, in: documentID) else { return }
        withAnimation(.snappy(duration: 0.2)) { selectedNodeIDs = [] }
        haptic()
        wwLog("Grouped \(group.memberIDs.count) graph nodes", .general)
        groupLabelText = ""
        labelingGroupID = group.id
    }

    // MARK: Selection bar

    /// What a selection can do, in the app's usual batch-bar shape but floating over the canvas:
    /// how many are held, what to do with them, and — along the bottom — the four ways to line them
    /// up. It stands up for the whole of selection mode, empty selection included, so the mode is
    /// never on without something on screen saying so.
    @ViewBuilder
    private func selectionBar() -> some View {
        if isSelecting || !selectedNodeIDs.isEmpty {
            VStack(spacing: 10) {
                // Tighter than it was: the colour dot makes four controls in this row, and the dot
                // brings 9 points of its own padding, so the gaps still read as gaps on a phone.
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selectedNodeIDs.isEmpty ? "Select nodes"
                                                     : "\(selectedNodeIDs.count) selected")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(WW.ink)
                        Text(selectedNodeIDs.isEmpty ? "Drag a box round them, or tap them one by one"
                                                     : "Drag any of them to move the lot")
                            .font(.caption2)
                            .foregroundStyle(WW.inkSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    // The ink for everything picked out — the same dot a single card carries in its
                    // edit bar, doing the same thing to a set of them. It leads the actions here for
                    // the same reason it leads that row: it's what these cards *are*.
                    if !selectedNodeIDs.isEmpty {
                        GraphColorDot(colorID: selectionColor, diameter: 16) { colorID in
                            colorSelection(colorID)
                        }
                    }
                    if selectedNodeIDs.count >= GraphGroup.minimumMembers {
                        Button { groupSelection() } label: {
                            Label("Group", systemImage: "square.dashed")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 17))
                                .foregroundStyle(WW.moss)
                                .frame(width: 40, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Group")
                    }
                    if !selectedNodeIDs.isEmpty {
                        Button { deleteSelection() } label: {
                            Label("Delete", systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 17))
                                .foregroundStyle(WW.ember)
                                .frame(width: 40, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        if isSelecting {
                            endSelecting()
                        } else {
                            withAnimation(.snappy(duration: 0.2)) { selectedNodeIDs = [] }
                        }
                    } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WW.moss)
                    }
                    .buttonStyle(.plain)
                }
                if selectedNodeIDs.count >= GraphArrange.minimumToAlign { arrangeRow() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: WW.contentMaxWidth)
            .background(WW.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(WW.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The four arrangements, as a row of their own under a rule: align the selection's left or top
    /// edges, or even out the gaps across or down. Distributing needs three cards to say anything —
    /// the two on the ends are what it holds still — so with two it's there but greyed.
    @ViewBuilder
    private func arrangeRow() -> some View {
        VStack(spacing: 8) {
            WWHairline()
            HStack(spacing: 0) {
                arrangeButton("Align Left", "align.horizontal.left") {
                    arrangeSelection("Align Left", GraphArrange.alignLeft)
                }
                arrangeButton("Align Top", "align.vertical.top") {
                    arrangeSelection("Align Top", GraphArrange.alignTop)
                }
                arrangeButton("Distribute Horizontal", "distribute.horizontal.center",
                              enabled: canDistribute) {
                    arrangeSelection("Distribute Horizontal", GraphArrange.distributeHorizontally)
                }
                arrangeButton("Distribute Vertical", "distribute.vertical.center",
                              enabled: canDistribute) {
                    arrangeSelection("Distribute Vertical", GraphArrange.distributeVertically)
                }
            }
        }
    }

    private var canDistribute: Bool {
        selectedNodeIDs.count >= GraphArrange.minimumToDistribute
    }

    /// The ink the selection is wearing, if they all wear the same one — what the bar's dot shows.
    /// A set that disagrees shows "no colour", since there's no one answer to show and picking one
    /// is how you make them agree.
    private var selectionColor: String? {
        guard let document else { return nil }
        // Nils kept, so a set where only some cards are coloured disagrees rather than reading as
        // the colour the coloured ones happen to share.
        let inks = selectedNodeIDs.map { document.node(with: $0)?.colorID }
        guard let ink = inks.first, inks.allSatisfy({ $0 == ink }) else { return nil }
        return ink
    }

    /// Give every selected card the same ink, or take it off the lot of them.
    private func colorSelection(_ colorID: String?) {
        let ids = selectedNodeIDs
        guard !ids.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) {
            for id in ids { model.documents.setNodeColor(id, in: documentID, to: colorID) }
        }
        haptic()
        wwLog("Coloured \(ids.count) graph node\(ids.count == 1 ? "" : "s") \(colorID ?? "plain")",
              .general)
    }

    private func arrangeButton(_ title: String, _ icon: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(WW.moss)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }

    // MARK: The bottom of the canvas — controls and minimap

    /// What sits along the bottom of the canvas: the two on-screen modifier keys at the left, the
    /// minimap across the middle, and **Auto tidy** at the right. The whole row stands down while a
    /// node is open for editing or a menu is up, where the keyboard and the dropdown want the room.
    ///
    /// The controls stay whether or not the minimap is shown — they're how the canvas is worked,
    /// not part of the map — so hiding the map doesn't take Auto tidy and the modifiers with it. It
    /// only takes the map, and the row keeps its shape: the keys stay left, Auto tidy stays right.
    @ViewBuilder
    private func bottomControls(for document: Document, edges: [GraphEdgeLine]) -> some View {
        if editingNodeID == nil, menuNodeID == nil {
            HStack(alignment: .bottom, spacing: 8) {
                modifierKeyColumn(for: document)
                if showsMinimap, !document.nodes.isEmpty {
                    minimap(for: document, edges: edges)
                } else {
                    Spacer(minLength: 0)
                }
                rightControlColumn(for: document)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    /// The two on-screen keys at the minimap's left: **⌘** and **⌥**. (**⇧** is a key too, but it
    /// lives on the other side — see `rightControlColumn`.)
    ///
    /// They're *keys*, not switches: you hold one down with one thumb and drag with the other,
    /// exactly as you'd hold the real thing, and it lets go the moment you do. That's what keeps
    /// them honest — whatever else these modifiers come to mean on this canvas, the buttons mean it
    /// too. Today ⌘ picks nodes out, pulls a dragged card out of the network and out of any ring it
    /// leaves, and — in a joint document — turns the other half's "+" into a caret; ⌥ drags a copy;
    /// ⇧ qualifies ⌘, so ⌘⇧ takes a card out of its ring and leaves the tree alone.
    private func modifierKeyColumn(for document: Document) -> some View {
        let hasNodes = !document.nodes.isEmpty
        return VStack(spacing: 8) {
            modifierKey("command", isOn: $modifierKeys.virtualCommand,
                        enabled: hasNodes,
                        label: "Hold to select nodes, or drag a node out of the network and its groups")
            modifierKey("option", isOn: $modifierKeys.virtualOption,
                        enabled: hasNodes,
                        label: "Hold to drag a copy")
        }
    }

    /// The right-hand stack: **⇧** over **Auto tidy**.
    ///
    /// ⇧ is the third key, and it's over here rather than on top of the other two so that neither
    /// side stands taller than the minimap between them. Two and two reads as the row it is; three
    /// and one left a column poking up past the map for the sake of a key that's greyed most of
    /// the time.
    ///
    /// It's **live only while ⌘ is**, because qualifying ⌘ is all it means here — on its own it
    /// would be a key that does nothing, and a key that does nothing is a key you press to find
    /// out. Drawn either way rather than appearing and vanishing: a button that moves out from
    /// under a thumb is worse than one that's greyed.
    private func rightControlColumn(for document: Document) -> some View {
        VStack(spacing: 8) {
            modifierKey("shift", isOn: $modifierKeys.virtualShift,
                        enabled: !document.nodes.isEmpty && isCommandEngaged,
                        label: "Hold with ⌘ to drag a node out of its group but not out of the network")
            autoTidyButton()
        }
    }

    /// **Auto tidy**, at the minimap's right — a setting rather than a key, so unlike the keys
    /// around it it's a toggle that stays where you put it.
    private func autoTidyButton() -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { autoTidy.toggle() }
            haptic()
            wwLog("Auto tidy \(autoTidy ? "on" : "off") for graphs", .general)
        } label: {
            canvasControlFace("rectangle.3.group", isOn: autoTidy)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto Tidy")
        .accessibilityAddTraits(autoTidy ? [.isSelected] : [])
    }

    /// One of the on-screen modifier keys. A press, not a tap: `onChanged` fires as the finger lands
    /// and `onEnded` when it leaves, so the key is down for exactly as long as the thumb is.
    private func modifierKey(_ icon: String, isOn: Binding<Bool>, enabled: Bool,
                             label: String) -> some View {
        canvasControlFace(icon, isOn: isOn.wrappedValue, enabled: enabled)
            // A key that stops being live lets go of itself: releasing ⌘ with ⇧ still held under
            // the other thumb would otherwise leave ⇧ down with nothing to qualify.
            .onChange(of: enabled) { _, live in
                if !live, isOn.wrappedValue { isOn.wrappedValue = false }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isOn.wrappedValue, enabled else { return }
                        withAnimation(.snappy(duration: 0.15)) { isOn.wrappedValue = true }
                        haptic(strong: true)
                    }
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.15)) { isOn.wrappedValue = false }
                    }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }

    /// One of those buttons, drawn: the minimap's own surface and hairline, filled in while it's on.
    private func canvasControlFace(_ icon: String, isOn: Bool, enabled: Bool = true) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isOn ? WW.paper : WW.moss)
            .frame(width: 42, height: 34)
            .background(isOn ? WW.moss : WW.surface.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isOn ? WW.moss : WW.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
    }

    /// The whole graph, small, along the bottom — every node a dot in its own colour, every group
    /// a ring in its own, with a box around what's on screen. Whether it's shown at all is
    /// `bottomControls`' business, since the row it sits in has to keep its shape without it.
    private func minimap(for document: Document, edges: [GraphEdgeLine]) -> some View {
        GraphMinimap(nodes: document.nodes, edges: edges, rings: minimapRings(in: document),
                     viewport: viewportInCanvas) { spot in
            center(on: spot, animated: false)
        }
        .equatable()
        .transition(.opacity)
    }

    /// The group rings as the map wants them: a plain rectangle and an ink each.
    ///
    /// Measured from **stored** positions rather than the live boxes the canvas draws with, for the
    /// same reason the dots are: the map is a picture of where the graph *is*, and a ring sliding
    /// about under a drag would repaint it sixty times a second to say nothing. Nor does it borrow
    /// `groupRings`' nesting gap — that exists so two rings on the canvas read as one inside the
    /// other, and at this size the pair would be a single thick line either way.
    private func minimapRings(in document: Document) -> [GraphMinimap.Ring] {
        document.groups.compactMap { group -> GraphMinimap.Ring? in
            var frame: CGRect?
            for id in group.memberIDs {
                guard let node = document.node(with: id) else { continue }
                let box = card(around: CGPoint(x: node.position.x, y: node.position.y), of: id)
                frame = frame.map { $0.union(box) } ?? box
            }
            guard let frame else { return nil }
            return GraphMinimap.Ring(rect: frame.insetBy(dx: -GraphCanvas.groupPadding,
                                                         dy: -GraphCanvas.groupPadding),
                                     color: WW.paletteColor(group.colorID) ?? WW.moss)
        }
    }

    /// Nothing, drawn: the view exists only to give `ModifierKeys` somewhere to watch from, so a
    /// drag begun with ⌘ (or ⌥) down knows to draw a box, or pull a copy out, instead of panning.
    @ViewBuilder
    private func commandKeyWatcher() -> some View {
        #if canImport(UIKit)
        CommandKeyWatcher(keys: keys).frame(width: 0, height: 0)
        #else
        EmptyView()
        #endif
    }

    /// Nothing, drawn, again: the canvas's hardware-keyboard shortcuts — see `GraphKeyCommands`.
    @ViewBuilder
    private func keyCommands() -> some View {
        #if canImport(UIKit)
        GraphKeyCommands(isActive: acceptsKeyCommands,
                         onDelete: { deleteSelection() },
                         onAlignLeft: { arrangeSelection("Align Left", GraphArrange.alignLeft) },
                         onAlignRight: { arrangeSelection("Align Right", GraphArrange.alignRight) },
                         onTidy: { tidyFromKeyboard() })
            .frame(width: 0, height: 0)
        #else
        EmptyView()
        #endif
    }

    /// Whether the canvas should be holding the keyboard: not while a node is open for editing —
    /// there the text view wants every key, Delete most of all — not under a menu, an alert or the
    /// recording sheet, and not once the canvas has been navigated away from. (A pushed-over screen
    /// leaves this view in the hierarchy, and a Delete pressed there must not quietly take cards off
    /// a canvas nobody is looking at.)
    private var acceptsKeyCommands: Bool {
        isOnScreen && editingNodeID == nil && menuNodeID == nil && labelingGroupID == nil
            && !showingRename && reviseTask == nil && transformTargetID == nil
    }

    /// ⌘T. With cards picked out it lines up **their** children — the selection is what you're
    /// working on — and with nothing picked out it tidies the whole graph, from the roots down.
    private func tidyFromKeyboard() {
        guard let document else { return }
        let heights = measuredHeights
        let picked = document.nodeEntries.map(\.node.id).filter { selectedNodeIDs.contains($0) }
        withAnimation(.snappy(duration: 0.25)) {
            if picked.isEmpty {
                model.documents.tidyGraph(in: documentID, heights: heights)
            } else {
                for id in picked {
                    model.documents.tidyChildren(of: id, in: documentID, heights: heights)
                }
            }
        }
        haptic()
        wwLog(picked.isEmpty ? "Tidied the whole graph"
                             : "Tidied the children of \(picked.count) graph node\(picked.count == 1 ? "" : "s")",
              .general)
    }

    /// What the canvas is currently showing, in canvas coordinates.
    private var viewportInCanvas: CGRect {
        guard canvasSize.width > 0, scale > 0 else { return .zero }
        return CGRect(x: -pan.x / scale, y: -pan.y / scale,
                      width: canvasSize.width / scale, height: canvasSize.height / scale)
    }

    // MARK: Node list

    /// Whether the *sheet* is up: the list is asked for by one flag, and a phone answers with a
    /// sheet where an iPad answers with the sidebar. Rotating an iPhone into a regular width with
    /// the sheet open hands it over to the sidebar, which is the right thing either way round.
    private var nodeListSheetPresented: Binding<Bool> {
        Binding(get: { showingNodeList && !showsNodeSidebar },
                set: { showingNodeList = $0 })
    }

    /// "List Nodes" on a phone: the graph as an indented list, over the canvas. Tapping a line
    /// closes the sheet and takes you to that node — the canvas is behind it, so it has to get out
    /// of the way to show you what it found.
    @ViewBuilder
    private func nodeListSheet(for document: Document) -> some View {
        NavigationStack {
            nodeList(for: document)
                .navigationTitle("Nodes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingNodeList = false }
                    }
                }
        }
    }

    /// The same list as a sidebar down the right of the canvas, for a screen with room for both.
    /// Nothing is covered, so a tap doesn't close it: the canvas slides to the node beside you and
    /// the list stays where it is, ready for the next one — which is what makes it a way of reading
    /// a graph rather than a way of jumping into one.
    @ViewBuilder
    private func nodeListSidebar(for document: Document) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nodes")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WW.ink)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showingNodeList = false }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(WW.moss)
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide the node list")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            WWHairline()
            nodeList(for: document)
        }
        .background(WW.paper)
    }

    /// The graph as an indented list, in the same order as the outline it exports — the way back to
    /// something you recorded twenty screens away and can no longer see.
    @ViewBuilder
    private func nodeList(for document: Document) -> some View {
        List {
            ForEach(document.nodeEntries) { entry in
                Button { goTo(entry.node) } label: {
                    nodeListRow(entry, in: document)
                }
                .buttonStyle(.plain)
                .wwRow()
            }
        }
        .wwList()
        .overlay {
            if document.nodes.isEmpty {
                WWEmptyState(title: "No nodes yet", systemImage: "list.bullet.indent")
            }
        }
    }

    /// Take the canvas to a node the list picked out, and ring it for a moment when it gets there.
    /// The sheet closes on its way (it's covering the answer); the sidebar stays.
    private func goTo(_ node: GraphNode) {
        if !showsNodeSidebar { showingNodeList = false }
        center(on: CGPoint(x: node.position.x, y: node.position.y))
        flash(node.id)
    }

    /// Ring a node briefly. Which node is view state and the border reads it, so the ring appears
    /// wherever that card is drawn; a clock lets go of it again, and a second flash cancels the
    /// first rather than letting an old timer put the ring out early.
    private func flash(_ nodeID: UUID) {
        highlightTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) { highlightedNodeID = nodeID }
        haptic()
        highlightTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(GraphCanvas.highlightDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { highlightedNodeID = nil }
        }
    }

    @ViewBuilder
    private func nodeListRow(_ entry: GraphNodeEntry, in document: Document) -> some View {
        HStack(spacing: 8) {
            // Depth as indentation, so the list reads like the outline the graph exports.
            if entry.depth > 0 {
                Color.clear.frame(width: CGFloat(entry.depth) * 16, height: 1)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(WW.inkTertiary)
            }
            // The same words the card shows — a heading's marker is invisible here too.
            Text(entry.node.hasText ? entry.node.displayText : "Empty node")
                .font(.subheadline)
                .foregroundStyle(entry.node.hasText ? WW.ink : WW.inkTertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if recording(for: entry.node, in: document) != nil {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(WW.inkTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Placing the canvas

    /// Open onto the graph rather than onto wherever the origin happens to be: the first time the
    /// canvas is measured, centre what's already there.
    private func placeCanvas(in size: CGSize, document: Document) {
        guard !didPlaceCanvas, size.width > 0 else { return }
        didPlaceCanvas = true
        pan = centeringPan(for: document, in: size)
    }

    private func centeringPan(for document: Document, in size: CGSize) -> CGPoint {
        let xs = document.nodes.map(\.position.x)
        let ys = document.nodes.map(\.position.y)
        let focus: CGPoint
        if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
            focus = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        } else {
            focus = .zero
        }
        return CGPoint(x: size.width / 2 - focus.x * scale, y: size.height / 2 - focus.y * scale)
    }

    /// Put a canvas point in the middle of the screen — where the node list and the minimap both
    /// send you.
    private func center(on spot: CGPoint, animated: Bool = true) {
        guard canvasSize.width > 0 else { return }
        stopGlide()
        let target = CGPoint(x: canvasSize.width / 2 - spot.x * scale,
                             y: canvasSize.height / 2 - spot.y * scale)
        if animated {
            withAnimation(.snappy(duration: 0.3)) { pan = target }
        } else {
            pan = target
        }
    }

    private func recenter() {
        guard let document, canvasSize.width > 0 else { return }
        stopGlide()
        withAnimation(.snappy(duration: 0.3)) {
            scale = 1
            pan = centeringPan(for: document, in: canvasSize)
        }
    }

    // MARK: Toolbar

    /// The graph's title, tappable to rename — in the navigation bar, or in the header this canvas
    /// draws for itself when it's half of a joint document.
    private func titleButton(for document: Document?) -> some View {
        Button {
            renameText = document?.title ?? ""
            showingRename = true
        } label: {
            Text(document?.title ?? "Graph")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WW.ink)
                .lineLimit(1)
        }
    }

    /// The **⋯** this canvas floats in its own top-right corner when it's half of a joint
    /// document — see the same method on `DocumentDetailView`.
    @ViewBuilder
    private func paneMenu(for document: Document?) -> some View {
        if let document {
            Menu { menuContent(for: document) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WW.moss)
                    .frame(width: 34, height: 34)
                    .background(WW.surface.opacity(0.94), in: Circle())
                    .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
                    .contentShape(Circle())
            }
            .shadow(color: .black.opacity(0.10), radius: 10, y: 2)
            .padding(.top, 8)
            .padding(.trailing, 12)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(for document: Document?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            titleButton(for: document)
        }
        if let document {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    menuContent(for: document)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /// What's in the graph's **⋯** menu, apart from where it's put.
    @ViewBuilder
    private func menuContent(for document: Document) -> some View {
        Button { copyOutline(document) } label: {
            Label("Copy Outline", systemImage: "doc.on.doc")
        }
        Button {
            shareItem = ShareItem(text: MarkdownBackup.markdown(for: document))
        } label: {
            Label("Share Outline", systemImage: "square.and.arrow.up")
        }
        Button { shareDocumentFile(document) } label: {
            Label("Share as Woods Whisper File", systemImage: "arrow.up.doc")
        }
        JointDocumentMenuItem(isJoined: isJoined,
                              onCreate: createJointCounterpart,
                              onSeparate: separateJoint)
        Divider()
        Button {
            if isSelecting { endSelecting() } else { beginSelecting() }
        } label: {
            Label(isSelecting ? "Stop Selecting" : "Select Nodes",
                  systemImage: isSelecting ? "xmark.circle" : "checkmark.circle")
        }
        .disabled(document.nodes.isEmpty)
        Button {
            withAnimation(.snappy(duration: 0.25)) { showingNodeList.toggle() }
        } label: {
            Label(showsNodeSidebar && showingNodeList ? "Hide Nodes" : "List Nodes",
                  systemImage: "list.bullet.indent")
        }
        Button { recenter() } label: {
            Label("Center Graph", systemImage: "scope")
        }
        Button {
            withAnimation(.snappy(duration: 0.2)) { showsMinimap.toggle() }
        } label: {
            Label(showsMinimap ? "Hide Minimap" : "Show Minimap", systemImage: "map")
        }
        // Half of a pair has no title to tap, so the rename lives here instead.
        if isEmbedded {
            Divider()
            Button {
                renameText = document.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
    }

    // MARK: Joint document

    /// Whether this graph is half of a pair.
    private var isJoined: Bool { model.documents.jointPartnerID(of: documentID) != nil }

    /// "Create Joint Document": make the prose half. This screen *becomes* the pair — see the same
    /// method on `DocumentDetailView` for why nothing is pushed.
    private func createJointCounterpart() {
        guard let counterpart = model.documents.createJointCounterpart(for: documentID) else { return }
        wwLog("Joined “\(counterpart.title)” to a new document", .general)
    }

    /// "Separate Joint Document": the halves go their own ways, both keeping everything in them.
    private func separateJoint() {
        model.documents.separateJoint(documentID)
        wwLog("Separated a joint document", .general)
    }

    /// The graph as a Markdown outline — nodes as bullets, indented by depth. It's what a graph
    /// copies, shares and backs up as (see `Document.outline`).
    private func copyOutline(_ document: Document) {
        #if canImport(UIKit)
        UIPasteboard.general.string = MarkdownBackup.markdown(for: document)
        #endif
        wwLog("Copied the outline of “\(document.title)” to clipboard", .general)
    }

    private func shareDocumentFile(_ document: Document) {
        if let url = model.exportDocumentFile(document.id) {
            documentFileShare = DocumentFileShareItem(url: url)
        }
    }

    // MARK: Small types

    /// Drives the `RecordingSheet` that records a node's replacement ("Revise").
    private struct ReviseTask: Identifiable {
        let nodeID: UUID
        var id: UUID { nodeID }
    }

    /// What a drag on a card turned out to be, decided by what was held when it began.
    private enum NodeDragMode {
        /// The card and its branch travel, and a drop on another card re-parents them.
        case move
        /// ⌘: the cards come out of the network the moment the drag starts — the old scissors, as
        /// a gesture — and out of any group's ring they're dragged clear of.
        case unlink
        /// ⌘⇧: out of the **ring** only. The card keeps its parent and its children and carries its
        /// branch like an ordinary move; all it loses is a group it's dragged clear of. Two ways to
        /// belong, and this is the gesture for shedding one of them without the other.
        case leaveGroup
        /// ⌥: a copy of the cards comes away, leaving the originals where they are.
        case copy

        /// Whether this drag takes its cards out of the rings they're carried clear of. The two
        /// gestures that mean "out of something" do; a move and a copy never remove a node from a
        /// group (see `updateGroupMembership`).
        var leavesGroups: Bool { self == .unlink || self == .leaveGroup }
    }

    /// One row of the long-press dropdown.
    private struct NodeMenuItem: Identifiable {
        let title: String
        let icon: String
        var isDestructive = false
        var enabled = true
        let action: () -> Void

        var id: String { title }

        init(title: String, icon: String, isDestructive: Bool = false, enabled: Bool = true,
             action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.isDestructive = isDestructive
            self.enabled = enabled
            self.action = action
        }
    }
}

// MARK: - Canvas constants

/// The handful of numbers the canvas is built from, in one place.
enum GraphCanvas {
    /// How much canvas is laid out at once. The user never meets an edge — panning moves the
    /// viewport, not the content — and this is simply big enough (±12,000 points, some 60 screens
    /// in every direction) that laying it out as one container costs nothing.
    static let extent: CGFloat = 24_000
    static var center: CGFloat { extent / 2 }

    static let nodeWidth: CGFloat = 180
    /// What a card is taken to be before it has been measured — the width it's drawn at, and the
    /// height of one with a line in it. `DocumentStore.nodeCardHeight` is the same number on the
    /// arranging side, which is what keeps a tidied gap the gap you can see.
    static var assumedCardSize: CGSize {
        CGSize(width: nodeWidth, height: CGFloat(DocumentStore.nodeCardHeight))
    }
    /// A node that's open for editing, which has an action row to fit as well as its text.
    static let editingNodeWidth: CGFloat = 280
    static let menuWidth: CGFloat = 210
    static let gridSpacing: CGFloat = 44
    static let minimapHeight: CGFloat = 76

    static let minScale: CGFloat = 0.35
    static let maxScale: CGFloat = 2.5

    /// How long a press has to hold still before it becomes a recording.
    static let holdDuration: TimeInterval = 0.4
    /// A clip shorter than this was a stray press, not something said.
    static let minimumClip: TimeInterval = 0.3
    /// How far the finger may roam from the node it's recording into before the next one begins.
    static let chainRadius: CGFloat = 96
    /// How still the finger has to be, and for how long, to count as having settled somewhere.
    static let settleSlop: CGFloat = 14
    static let settleDelay: TimeInterval = 1.0
    /// How far above a card its quick actions float — the bar's own height plus a few points of
    /// air, so it clears the card without leaving a gulf for the pointer to cross on its way there.
    static let quickActionsLift: CGFloat = 38
    /// How long the quick actions stay up once nothing is pointing at them: long enough for a
    /// pointer to travel from the card to the bar, short enough that a bar nobody wanted goes away
    /// while you're still looking at it.
    static let quickActionsGrace: TimeInterval = 0.6
    /// How strongly a chosen colour washes the inside of a card or a group's ring: enough to tell
    /// two clusters apart across a canvas, faint enough to read text over in either theme.
    static let tintOpacity: Double = 0.12
    /// Air between a group's ring and the cards inside it, and how thick its draggable edge is.
    static let groupPadding: CGFloat = 26
    /// Air between a ring and a ring nested inside it, so the two read as one inside the other
    /// rather than as a single thick line.
    static let nestedGroupGap: CGFloat = 10
    static let groupBorderGrab: CGFloat = 28
    /// How far a touch may drift and still count as a press rather than a pan.
    static let tapSlop: CGFloat = 12
    /// Below this release speed (points per second) a pan simply stops where it is.
    static let glideThreshold: CGFloat = 150
    /// What's left of the speed after each frame of coasting — a flick runs on for about a second.
    static let glideDecay: CGFloat = 0.94
    static let doubleTapWindow: TimeInterval = 0.35

    /// How wide the node list sits when it's a sidebar rather than a sheet: enough for two lines of
    /// a node at a readable size, without taking the canvas's half of the screen.
    static let nodeListWidth: CGFloat = 300
    /// How long a node keeps its ring after the list sends you to it — long enough to find it,
    /// short enough not to be mistaken for a state the node is in.
    static let highlightDuration: TimeInterval = 1.4
}

// MARK: - Edges

/// One parent→child curve, in canvas coordinates. Named by the child, since that's the node the
/// edge belongs to: insert a node "on" this edge and the child is what it adopts.
///
/// It's a cubic Bézier rather than a straight line: it leaves each card square-on to the side it's
/// attached to — the same way the straight line met it — runs that way a little, and only then
/// bends towards the other end. Two cards side by side are still joined by what looks like a
/// straight line; one sitting high or low gets an S rather than a diagonal across the gap.
struct GraphEdgeLine: Identifiable {
    let id: UUID
    let parentID: UUID
    let from: CGPoint
    /// The way the parent's side faces — the direction the curve sets off in.
    let facing: CGVector
    let to: CGPoint
    /// The way the child's side faces, which the curve arrives against.
    let entering: CGVector

    /// How far one end holds the line it left on before it turns: half the gap measured **along
    /// that side's own axis**, so two cards facing each other across the standard 150 points have
    /// their two controls meet in the middle — a clean S rather than one overshooting the other.
    /// Held between a nudge and half a card, so a stacked pair still curves and a distant one
    /// doesn't billow out across the canvas.
    private func reach(along normal: CGVector) -> CGFloat {
        let gap = abs(normal.dx) > abs(normal.dy) ? abs(to.x - from.x) : abs(to.y - from.y)
        return min(max(gap / 2, 16), GraphCanvas.nodeWidth / 2)
    }

    var fromControl: CGPoint {
        let out = reach(along: facing)
        return CGPoint(x: from.x + facing.dx * out, y: from.y + facing.dy * out)
    }

    var toControl: CGPoint {
        let out = reach(along: entering)
        return CGPoint(x: to.x + entering.dx * out, y: to.y + entering.dy * out)
    }

    /// The middle of the **curve** — `B(0.5)` of the cubic, which reduces to this — where the "+"
    /// that inserts a node on this edge sits. Half way along the straight line between two cards
    /// isn't on the curve at all once it bends, and the button would hang off it.
    var midpoint: CGPoint {
        CGPoint(x: (from.x + 3 * fromControl.x + 3 * toControl.x + to.x) / 8,
                y: (from.y + 3 * fromControl.y + 3 * toControl.y + to.y) / 8)
    }
}

/// Every edge as one stroked path — cheaper than a view per line, and it can't get out of step with
/// the nodes because both read the same positions.
private struct GraphEdgeShape: Shape {
    let edges: [GraphEdgeLine]

    func path(in rect: CGRect) -> Path {
        // The canvas container is laid out around its own centre, so everything drawn in canvas
        // coordinates is offset by it.
        func placed(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + GraphCanvas.center, y: point.y + GraphCanvas.center)
        }
        var path = Path()
        for edge in edges {
            path.move(to: placed(edge.from))
            path.addCurve(to: placed(edge.to),
                          control1: placed(edge.fromControl),
                          control2: placed(edge.toControl))
        }
        return path
    }
}

// MARK: - Grid

/// The very light grid under the graph: lines every `gridSpacing` canvas points, drawn in view
/// space so panning slides them and zooming spaces them out. Zoom far enough out and the spacing
/// doubles rather than closing into a wash of ink.
private struct GraphGrid: View {
    let pan: CGPoint
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            var spacing = max(GraphCanvas.gridSpacing * scale, 8)
            while spacing < 18 { spacing *= 2 }

            var path = Path()
            var x = pan.x.truncatingRemainder(dividingBy: spacing)
            if x > 0 { x -= spacing }
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = pan.y.truncatingRemainder(dividingBy: spacing)
            if y > 0 { y -= spacing }
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(WW.hairline.opacity(0.65)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The colour dot

/// The dot that gives a node or a group its ink: a small filled circle that opens the palette.
///
/// Two places carry it, and they're the two things on a canvas you'd want to tell apart at a
/// glance — the head of a node's edit bar, and the corner of a group's ring. Both store the same
/// kind of id (`GraphPalette.colorIDs`, the names Inbox tags already use), so both get the same
/// control rather than two that look alike.
///
/// The palette opens as a **popover** rather than a menu, on a phone as much as an iPad
/// (`presentationCompactAdaptation`), because a colour picker that shows no colours is no use: a
/// menu row can carry the name but not the ink, and a row of dots says it without a word. Picking
/// one closes it; the crossed-through dot at the end takes the colour off again.
///
/// Four places carry the dot now — a node's edit bar, a ring's corner, the selection bar (where it
/// colours everything picked out) and the group sheet, which shows the row itself rather than a dot
/// that opens one, having the room.
struct GraphColorDot: View {
    let colorID: String?
    var diameter: CGFloat = 14
    let onPick: (String?) -> Void

    @State private var showingPalette = false

    var body: some View {
        Button { showingPalette = true } label: {
            GraphColorSwatch(colorID: colorID, diameter: diameter)
                .padding(9)                 // a 14-point dot is not a 14-point target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour")
        .popover(isPresented: $showingPalette) {
            GraphColorRow(colorID: colorID) { picked in
                onPick(picked)
                showingPalette = false
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The palette itself: every ink as a dot, and "no colour" at the end. What the dot's popover
/// shows, and what the group sheet lays out inline.
struct GraphColorRow: View {
    let colorID: String?
    var diameter: CGFloat = 26
    let onPick: (String?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(GraphPalette.colorIDs, id: \.self) { pick($0) }
            pick(nil)
        }
    }

    private func pick(_ id: String?) -> some View {
        Button { onPick(id) } label: {
            GraphColorSwatch(colorID: id, diameter: diameter)
                .overlay {
                    if id == colorID {
                        Circle().stroke(WW.ink, lineWidth: 2).padding(-4)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(id.map(Self.name) ?? "No colour")
        .accessibilityAddTraits(id == colorID ? [.isSelected] : [])
    }

    /// "violet" → "Violet". The stored ids are the display names, lowercased.
    static func name(_ id: String) -> String { id.prefix(1).uppercased() + String(id.dropFirst()) }
}

/// One dot: the colour filled in, or — for "no colour" — the plain card's own hairline ring with a
/// line through it.
struct GraphColorSwatch: View {
    let colorID: String?
    var diameter: CGFloat = 14

    var body: some View {
        if let color = WW.paletteColor(colorID) {
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .overlay(Circle().stroke(WW.ink.opacity(0.15), lineWidth: 1))
        } else {
            Circle()
                .fill(WW.surface)
                .frame(width: diameter, height: diameter)
                .overlay(Circle().stroke(WW.inkTertiary, lineWidth: 1))
                .overlay {
                    Rectangle()
                        .fill(WW.inkTertiary)
                        .frame(width: 1, height: diameter)
                        .rotationEffect(.degrees(45))
                }
        }
    }
}

// MARK: - The "+" button

/// The small "+" that adds something where it sits — and, held rather than tapped, records into
/// whatever it adds.
///
/// **Tap** it and what it makes opens for typing (or, from a list row, opens the document it would
/// write into); **hold** it and what it makes starts recording instead, until you let go. It turns
/// into a red dot while it's recording, the way the record button does. Three places use it now —
/// a node's right edge (add a child), the midpoint of a line (insert a node between the two it
/// joins), and a row of the Documents list — so it knows about none of them.
///
/// Explicitly main-actor: unlike the views around it, this one holds no `@EnvironmentObject` to
/// infer that from, and its gesture reaches the shared haptics.
@MainActor
struct HoldablePlusButton: View {
    /// The whole button, padding and all. A 22-point dot is half of what a finger needs, so it
    /// carries a fixed 44-point target whatever size the dot is drawn at — and a caller lining the
    /// dot up on something (a node's right edge) can work from one number.
    static let target: CGFloat = 42

    var diameter: CGFloat = 22
    let onTap: () -> Void
    let onHold: () -> Void
    let onRelease: () -> Void

    /// The gesture this press belongs to, so a touch the system cancels can't leave the button
    /// stuck "pressed" for good — the next one to begin elsewhere takes over.
    @State private var gestureStart: CGPoint?
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?
    /// Whether the finger wandered off before the hold armed — a swipe that happened to start here
    /// (a list row's swipe actions, say) rather than a press meant for this button.
    @State private var strayed = false

    var body: some View {
        Image(systemName: holding ? "circle.fill" : "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(holding ? WW.ember : WW.moss)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(WW.surface))
            .overlay(Circle().stroke(holding ? WW.ember : WW.hairline, lineWidth: 1))
            .scaleEffect(gestureStart == nil ? 1 : 0.92)
            // A 22-point dot is a 22-point target, which is half of what a finger needs. The
            // padding gives it a proper one without drawing anything bigger; it grows evenly, so
            // wherever the dot was centred it stays.
            .padding((Self.target - diameter) / 2)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if gestureStart != value.startLocation {
                            gestureStart = value.startLocation
                            strayed = false
                            WWHaptics.prepare()      // a hold is 0.4s away; warm the engine now
                            holdTask?.cancel()
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: UInt64(GraphCanvas.holdDuration * 1_000_000_000))
                                guard !Task.isCancelled, gestureStart != nil else { return }
                                holding = true
                                onHold()
                            }
                            return
                        }
                        // Once it's recording the finger may drift where it likes — that's the hold.
                        // Before that, travelling means this touch was on its way somewhere else.
                        guard !holding, !strayed,
                              hypot(value.translation.width, value.translation.height) > GraphCanvas.tapSlop
                        else { return }
                        strayed = true
                        holdTask?.cancel()
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        holdTask = nil
                        gestureStart = nil
                        if holding {
                            holding = false
                            onRelease()
                        } else if !strayed {
                            onTap()
                        }
                        strayed = false
                    }
            )
    }
}

// MARK: - The ⌘ and ⌥ keys

/// Which modifiers were held when the touch in progress began — what turns a drag on the canvas
/// into a selection box instead of a pan (⌘), or into a copy of what's being dragged (⌥), for
/// anyone working with a keyboard attached.
///
/// A class, and read through the reference rather than as `@State`, on purpose: a SwiftUI gesture
/// closure sees the view as it was when the body was last evaluated, and a modifier pressed between
/// two frames of the same drag would be missed. Reading it through an object gets the value as it is
/// now. Nothing here publishes either: the flags are consulted when a gesture starts, never drawn —
/// so a key going down redraws nothing.
///
/// Written and read on the main thread only: UIKit delivers touches there, and so does SwiftUI.
final class ModifierKeys {
    /// Set at every touch-down from the event's own modifier flags, so they describe *this* touch.
    var isCommandDown = false
    var isOptionDown = false
    var isShiftDown = false
}

/// Whether a hardware modifier is down *right now* — as against what was held when a touch began,
/// which is `ModifierKeys` above and a different question.
///
/// Two mechanisms because there are two questions. A drag only needs to know what was held when it
/// started, and a touch carries that with it. But the canvas has to be *drawn* differently while a
/// key is down — the cards change what a tap means, a node's quick actions appear under the pointer
/// with nothing touched at all, and a document's "+" says whether it will record or open an
/// editor — which needs the press itself, as it happens.
///
/// SwiftUI has no answer for that on iOS (`onModifierKeysChanged` is macOS), and the responder
/// chain is the wrong shape for it: presses go to whatever is first responder, which here is a text
/// view or nothing at all. GameController's keyboard is neither — it reports the state of the keys
/// on the device, whoever happens to be typing — so that's what this watches. One shared watcher:
/// a joint document has two canvases in it, and they're asking about the same keyboard.
///
/// With no hardware keyboard there's nothing to report and both stay false, which is exactly the
/// case the ⌘ and ⌥ buttons beside the minimap exist for.
final class ModifierKeyMonitor: ObservableObject {
    static let shared = ModifierKeyMonitor()

    @Published private(set) var isCommandDown = false
    @Published private(set) var isOptionDown = false
    /// Shift, watched for one reason: **Return** commits a node being edited, and shift + Return is
    /// how you say "no, I really do want a line break". A `UITextView` is handed the same "\n"
    /// either way, so the only way to tell the two apart is to ask the keyboard what else is down.
    @Published private(set) var isShiftDown = false

    /// The **⌘ and ⌥ buttons** beside a canvas's minimap, held with a thumb where there's no
    /// keyboard to hold the real thing. They live here rather than in the canvas that draws them
    /// because a *joint* document is two panes of one screen: the canvas's ⌘ has to reach the
    /// document half as well, where it turns the "+" between sections into a caret, exactly as the
    /// hardware key does. One shared pair of soft keys, read wherever a modifier is read.
    @Published var virtualCommand = false
    @Published var virtualOption = false
    @Published var virtualShift = false

    /// ⌘ as anything on screen should read it: the key, or the button standing in for it.
    var commandDown: Bool { isCommandDown || virtualCommand }
    var optionDown: Bool { isOptionDown || virtualOption }
    /// ⇧ the same way — for the gestures. **Return** asks `isShiftDown` instead: whether a line
    /// break was meant is a question about the keyboard that typed it, and a canvas button held
    /// under a thumb has nothing to say about that.
    var shiftDown: Bool { isShiftDown || virtualShift }

    #if canImport(GameController)
    private var observers: [NSObjectProtocol] = []

    private init() {
        watch(GCKeyboard.coalesced)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect,
                                            object: nil, queue: .main) { [weak self] note in
            self?.watch(note.object as? GCKeyboard ?? GCKeyboard.coalesced)
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.report(command: false)
            self?.report(option: false)
            self?.report(shift: false)
        })
    }

    /// Each key watched separately: either side down means the modifier is down, and letting one go
    /// while the other is still held shouldn't read as letting go.
    private func watch(_ keyboard: GCKeyboard?) {
        guard let input = keyboard?.keyboardInput else { return }
        for code in [GCKeyCode.leftGUI, GCKeyCode.rightGUI] {
            input.button(forKeyCode: code)?.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.report(command: pressed || Self.isDown(.leftGUI, .rightGUI))
            }
        }
        for code in [GCKeyCode.leftAlt, GCKeyCode.rightAlt] {
            input.button(forKeyCode: code)?.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.report(option: pressed || Self.isDown(.leftAlt, .rightAlt))
            }
        }
        for code in [GCKeyCode.leftShift, GCKeyCode.rightShift] {
            input.button(forKeyCode: code)?.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.report(shift: pressed || Self.isDown(.leftShift, .rightShift))
            }
        }
    }

    private static func isDown(_ codes: GCKeyCode...) -> Bool {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        return codes.contains { input.button(forKeyCode: $0)?.isPressed == true }
    }
    #else
    private init() {}
    #endif

    /// Handlers arrive on whichever queue GameController feels like; published state has to change
    /// on the main one.
    private func report(command down: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCommandDown != down else { return }
            withAnimation(.snappy(duration: 0.15)) { self.isCommandDown = down }
        }
    }

    private func report(option down: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOptionDown != down else { return }
            withAnimation(.snappy(duration: 0.15)) { self.isOptionDown = down }
        }
    }

    /// Shift changes nothing that's drawn — it only decides what a Return means — so it's set
    /// without an animation around it.
    private func report(shift down: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShiftDown != down else { return }
            self.isShiftDown = down
        }
    }
}

#if canImport(UIKit)
/// Reports the modifier keys held at each touch-down into a `ModifierKeys`.
///
/// UIKit tells the truth about this and SwiftUI has no answer for it on iOS at all: a `UIEvent`
/// carries the modifier flags that were down when it happened, so one passive recognizer on the
/// window sees what the keyboard was doing as each touch begins. The recognizer fails itself immediately and
/// cancels nothing, so it observes the touch without ever taking part in it — the canvas's own
/// gestures are untouched.
struct CommandKeyWatcher: UIViewRepresentable {
    let keys: ModifierKeys

    func makeUIView(context: Context) -> WatcherView { WatcherView(keys: keys) }
    func updateUIView(_ view: WatcherView, context: Context) {}

    /// A view of no size that takes no touches: it exists to find the window and hang the probe
    /// off it, since a recognizer only sees touches that land in its own view. Leaving the
    /// hierarchy moves it to no window at all, which is where the probe is taken back off.
    final class WatcherView: UIView {
        private let probe: Probe

        init(keys: ModifierKeys) {
            probe = Probe(keys: keys)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(probe)
        }

        func detach() { probe.view?.removeGestureRecognizer(probe) }
    }

    /// A recognizer that never recognizes. It reads the flags off the event and fails, which leaves
    /// every other gesture on screen exactly as it was.
    final class Probe: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let keys: ModifierKeys

        init(keys: ModifierKeys) {
            self.keys = keys
            super.init(target: nil, action: nil)
            delegate = self
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            keys.isCommandDown = event.modifierFlags.contains(.command)
            keys.isOptionDown = event.modifierFlags.contains(.alternate)
            keys.isShiftDown = event.modifierFlags.contains(.shift)
            state = .failed          // never recognize; never take a touch from anything else
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

#if canImport(UIKit)
/// The canvas's hardware-keyboard shortcuts, for anyone working with a keyboard attached:
/// **Delete** removes the selected cards, **⌘←** and **⌘→** line them up by their left or right
/// edges, and **⌘T** tidies — the selection's children, or the whole graph when nothing is picked
/// out.
///
/// UIKit's key commands rather than SwiftUI's `onKeyPress`, for one reason: the responder chain
/// already answers the question "is the user typing?". A view that's first responder gets the keys;
/// a text view that takes over gets them instead, and this stands down. `isActive` is the same idea
/// from the other end — a node open for editing, a menu, an alert — and it's watched for *changes*
/// rather than asserted on every update, so a keyboard that has moved on to the document half of a
/// joint document isn't dragged back here every time the canvas redraws.
struct GraphKeyCommands: UIViewRepresentable {
    /// Whether the canvas should be holding the keyboard right now.
    var isActive: Bool
    let onDelete: () -> Void
    let onAlignLeft: () -> Void
    let onAlignRight: () -> Void
    let onTidy: () -> Void

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        configure(view)
        return view
    }

    func updateUIView(_ view: KeyView, context: Context) { configure(view) }

    static func dismantleUIView(_ view: KeyView, coordinator: ()) {
        view.resignFirstResponder()
    }

    private func configure(_ view: KeyView) {
        view.onDelete = onDelete
        view.onAlignLeft = onAlignLeft
        view.onAlignRight = onAlignRight
        view.onTidy = onTidy
        view.wantsKeys(isActive)
    }

    /// A view of no size whose only job is to be first responder and carry the commands.
    final class KeyView: UIView {
        var onDelete: () -> Void = {}
        var onAlignLeft: () -> Void = {}
        var onAlignRight: () -> Void = {}
        var onTidy: () -> Void = {}

        private var holdingKeys = false

        override var canBecomeFirstResponder: Bool { true }

        /// Take the keyboard, or let it go — but only when the answer has changed, so an ordinary
        /// redraw never snatches focus back from whatever has it now.
        func wantsKeys(_ wanted: Bool) {
            guard wanted != holdingKeys else { return }
            holdingKeys = wanted
            if wanted { becomeFirstResponder() } else { resignFirstResponder() }
        }

        /// `makeUIView` runs before the view is in a window, where becoming first responder can't
        /// work; this is the moment it can.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if holdingKeys, window != nil { becomeFirstResponder() }
        }

        override var keyCommands: [UIKeyCommand]? {
            // Both delete keys by their characters rather than by name: backspace is what a Mac
            // keyboard's Delete sends, and DEL is what a full-size keyboard's forward delete does.
            let commands = [
                UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteSelection)),
                UIKeyCommand(input: "\u{7F}", modifierFlags: [], action: #selector(deleteSelection)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .command,
                             action: #selector(alignLeft)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .command,
                             action: #selector(alignRight)),
                UIKeyCommand(input: "t", modifierFlags: .command, action: #selector(tidy))
            ]
            // Otherwise the system keeps the arrows for itself (focus movement) before this is asked.
            for command in commands { command.wantsPriorityOverSystemBehavior = true }
            return commands
        }

        @objc private func deleteSelection() { onDelete() }
        @objc private func alignLeft() { onAlignLeft() }
        @objc private func alignRight() { onAlignRight() }
        @objc private func tidy() { onTidy() }
    }
}
#endif

// MARK: - Minimap

/// The whole graph in a strip along the bottom of the canvas: one dot per node — filled for a node
/// with words, hollow for one still waiting on them — inside a box showing what's on screen.
///
/// Every node is a dot and every parent→child link a hairline between two of them — the *same*
/// curves the canvas draws, handed in rather than guessed at, so the map is a small picture of the
/// graph and not a diagram of it.
///
/// Touch anywhere on it (or drag across it) to go there. With no simulation moving nodes about,
/// where a dot sits on this map is exactly where the node is, which is what makes it a map.
///
/// `Equatable`, and drawn through `.equatable()`, so a drag doesn't redraw it sixty times for
/// nothing: dragging a node changes neither the stored positions nor the viewport, and comparing
/// the two things this map is made of is far cheaper than painting every dot again. The comparison
/// leaves `onGo` out — a closure can't be compared, and this one only reaches view state through
/// bindings, so an older copy of it does exactly what a fresh one would.
private struct GraphMinimap: View, Equatable {
    let nodes: [GraphNode]
    /// The curves between them, as the canvas has them — control points and all, so the map bends
    /// the way the canvas does.
    let edges: [GraphEdgeLine]
    /// The rings, as rectangles in canvas points — see `Ring` and `GraphDocumentView.minimapRings`.
    let rings: [Ring]
    /// What the canvas is showing, in canvas points.
    let viewport: CGRect
    /// The canvas point the user picked out.
    let onGo: (CGPoint) -> Void

    /// One group on the map: where its ring falls, and the ink it's drawn in. A rectangle rather
    /// than the group itself, because the map has no cards to measure a ring from — the canvas
    /// works that out once and hands the answer over.
    struct Ring: Equatable {
        let rect: CGRect
        let color: Color
    }

    /// Compared on the nodes, the rings and the viewport. The edges are worked out from those same
    /// positions (plus the measured cards), so they can't change without one of these changing —
    /// and leaving them out keeps a drag from repainting a map that, drawn from *stored* positions,
    /// isn't moving anyway.
    static func == (lhs: GraphMinimap, rhs: GraphMinimap) -> Bool {
        lhs.viewport == rhs.viewport && lhs.nodes == rhs.nodes && lhs.rings == rhs.rings
    }

    var body: some View {
        GeometryReader { geo in
            let fit = mapping(in: geo.size)
            Canvas { context, _ in
                // What's on screen, as a box.
                let box = CGRect(origin: project(CGPoint(x: viewport.minX, y: viewport.minY), fit),
                                 size: CGSize(width: viewport.width * fit.scale,
                                              height: viewport.height * fit.scale))
                context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(WW.moss.opacity(0.10)))
                context.stroke(Path(roundedRect: box, cornerRadius: 3),
                               with: .color(WW.moss.opacity(0.7)), lineWidth: 1)

                // The groups, under the links and the dots alike: the same dashed ring in the
                // same ink, washed inside the same way, so a cluster you picked out by its colour
                // on the canvas is the cluster you reach for on the map. A ring is what the nodes
                // sit *in*, so it's laid down before them.
                for ring in rings {
                    let frame = CGRect(origin: project(CGPoint(x: ring.rect.minX, y: ring.rect.minY), fit),
                                       size: CGSize(width: ring.rect.width * fit.scale,
                                                    height: ring.rect.height * fit.scale))
                    let shape = Path(roundedRect: frame, cornerRadius: 4)
                    context.fill(shape, with: .color(ring.color.opacity(GraphCanvas.tintOpacity)))
                    context.stroke(shape, with: .color(ring.color.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
                }

                // The links, under the dots: the canvas's own curves, every point run through the
                // same projection the dots are, so a link on the map leaves and arrives exactly
                // where it does on the canvas. One path for the lot — it's the *shape* of the graph
                // the map is for, and a hundred separate strokes would say the same thing slower.
                var links = Path()
                for edge in edges {
                    links.move(to: project(edge.from, fit))
                    links.addCurve(to: project(edge.to, fit),
                                   control1: project(edge.fromControl, fit),
                                   control2: project(edge.toControl, fit))
                }
                context.stroke(links, with: .color(WW.inkTertiary.opacity(0.55)), lineWidth: 0.75)

                for node in nodes {
                    let point = project(CGPoint(x: node.position.x, y: node.position.y), fit)
                    let dot = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                    // A card's own ink, where it has one — the dot is the card, small, and a
                    // colour that means something on the canvas has to mean it here too.
                    let ink = WW.paletteColor(node.colorID)
                    if node.hasText {
                        context.fill(Path(ellipseIn: dot), with: .color(ink ?? WW.ink))
                    } else {
                        // Nothing said into it yet: an outline rather than a dot, in its colour if
                        // it has been given one.
                        context.stroke(Path(ellipseIn: dot), with: .color(ink ?? WW.inkTertiary),
                                       lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onGo(unproject(value.location, fit)) }
            )
        }
        .frame(height: GraphCanvas.minimapHeight)
        .frame(maxWidth: WW.contentMaxWidth)
        .background(WW.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(WW.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
    }

    /// How canvas points map onto the map: everything there is, plus what's on screen, fitted with
    /// room to spare so a node never sits on the very edge.
    private struct Fit {
        let scale: CGFloat
        let offset: CGPoint
    }

    private func mapping(in size: CGSize) -> Fit {
        var minX = viewport.minX, maxX = viewport.maxX
        var minY = viewport.minY, maxY = viewport.maxY
        for node in nodes {
            minX = min(minX, CGFloat(node.position.x))
            maxX = max(maxX, CGFloat(node.position.x))
            minY = min(minY, CGFloat(node.position.y))
            maxY = max(maxY, CGFloat(node.position.y))
        }
        // A ring reaches further than the dots inside it, so it's fitted as well — otherwise the
        // outermost group would be drawn with its edge off the side of the map.
        for ring in rings {
            minX = min(minX, ring.rect.minX)
            maxX = max(maxX, ring.rect.maxX)
            minY = min(minY, ring.rect.minY)
            maxY = max(maxY, ring.rect.maxY)
        }
        let padding: CGFloat = 160
        let width: CGFloat = max(maxX - minX + padding * 2, 1)
        let height: CGFloat = max(maxY - minY + padding * 2, 1)
        let scale: CGFloat = min(size.width / width, size.height / height)
        let offset = CGPoint(x: (size.width - width * scale) / 2 - (minX - padding) * scale,
                             y: (size.height - height * scale) / 2 - (minY - padding) * scale)
        return Fit(scale: scale, offset: offset)
    }

    private func project(_ point: CGPoint, _ fit: Fit) -> CGPoint {
        CGPoint(x: point.x * fit.scale + fit.offset.x, y: point.y * fit.scale + fit.offset.y)
    }

    private func unproject(_ point: CGPoint, _ fit: Fit) -> CGPoint {
        guard fit.scale > 0 else { return .zero }
        return CGPoint(x: (point.x - fit.offset.x) / fit.scale,
                       y: (point.y - fit.offset.y) / fit.scale)
    }
}
