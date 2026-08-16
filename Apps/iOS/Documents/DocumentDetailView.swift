import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
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
    let documentID: UUID

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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(for: document) }
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
                           onRecord: { recorderTask = .addToRecordings })
            }
        }
        .overlay(alignment: .top) {
            if isTransformingDoc {
                BusyBanner(message: "Transforming document…").padding(.top, 8)
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
                InsertHereButton(isRecording: recorderTask == .insertBody(at: 0)) {
                    startInsert(at: 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                if !editMode.isEditing {
                    InsertHereButton(isRecording: recorderTask == .insertBody(at: 0)) {
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
                InsertHereButton(isRecording: recorderTask == .insertBody(at: position)) {
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
                Text("Transforming…").foregroundStyle(WW.inkSecondary)
            }
        } else {
            Text(para.text)
                .font(WW.bodyText)
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

    @ToolbarContentBuilder
    private func toolbarContent(for document: Document?) -> some ToolbarContent {
        // Tappable document title — opens the rename editor.
        ToolbarItem(placement: .principal) {
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

        if editMode.isEditing {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { withAnimation { editMode = .inactive } }
            }
        } else {
            // No mic up here any more: recording is the red button above the bottom bar.
            if let document {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        TextImportItems(onClipboard: importFromClipboard,
                                        onFile: { showingTextImporter = true })
                        Divider()
                        Button { shareDocumentFile(document) } label: {
                            Label("Share as Woods Whisper File", systemImage: "arrow.up.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
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

    /// Tap "+": record a clip whose transcript becomes a new section at `position`.
    ///
    /// With an editor open, the buffer is committed first — and committing can change how many
    /// paragraphs sit above the slot (blank lines split it in two; emptying it removes it), so the
    /// slot is re-reckoned before the recorder is handed it. Only an edit *above* the slot moves it.
    private func startInsert(at position: Int) {
        if let id = editingParagraphID {
            let index = document?.paragraphs.firstIndex(where: { $0.id == id })
            let resulting = Document.paragraphs(from: editingText).count
            finishEditing()
            if let index, index < position {
                recorderTask = .insertBody(at: max(0, position + resulting - 1))
                return
            }
        }
        recorderTask = .insertBody(at: position)
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
private struct InsertHereButton: View {
    var isRecording: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                rule
                Image(systemName: isRecording ? "circle.fill" : "plus")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(isRecording ? WW.ember : WW.inkTertiary)
                rule
            }
        }
        .buttonStyle(.plain)
        .disabled(isRecording)
        .padding(.top, 4)
        .padding(.bottom, 16)
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
    /// What the red dot does — or nil in a **graph** document, which has no record button of its
    /// own: recording there is a hold anywhere on the canvas, which places the node at the same
    /// time. The Auto transform toggle below is the same in all three places.
    let onRecord: (() -> Void)?

    /// Whether the toggle reads as on. Held locally as well as in the store because "on, but no
    /// transform picked yet" is a real state: it's what you see between flipping the switch and
    /// choosing from the list.
    @State private var isOn = false
    @State private var showingList = false

    var body: some View {
        VStack(spacing: 0) {
            // No background behind the dot — the list's text passes underneath it. The padding is
            // lopsided on purpose: it lifts the dot clear of the bar without changing the height
            // this inset takes from the list.
            if let onRecord {
                WWRecordButton(action: onRecord)
                    .padding(.bottom, 20)
            }

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
        }
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

    var body: some View {
        #if canImport(UIKit)
        InlineUITextEditor(text: $text, selection: $selection, style: style)
        #else
        TextEditor(text: $text).font(style.font).frame(minHeight: 120)
        #endif
    }
}

/// Where a piece of in-line editable text lives, and so how it's set. Each case pairs the SwiftUI
/// type the row draws with the UIKit type the editor uses, which is the whole point: they have to
/// match, or the text jumps size the moment you tap it.
enum InlineTextStyle {
    /// A paragraph of a document body: `WW.bodyText` at `.lineSpacing(5)`.
    case documentBody
    /// An Inbox entry's transcript: the `.subheadline` its preview is set in.
    case inboxTranscript
    /// A node on a graph canvas — the same compact type an Inbox entry is set in, since a node card
    /// is the same small block of text.
    case graphNode

    /// What the row uses to draw the text.
    var font: Font {
        switch self {
        case .documentBody:                 return WW.bodyText
        case .inboxTranscript, .graphNode:  return .subheadline
        }
    }

    #if canImport(UIKit)
    /// The same type, as UIKit sees it. `.systemFont(ofSize: 17)` rather than the preferred `.body`
    /// font, because `WW.bodyText` is a fixed 17 — the preferred one is 17 only at the default Text
    /// Size setting, and grows past it everywhere else.
    var uiFont: UIFont {
        switch self {
        case .documentBody:                 return .systemFont(ofSize: 17)
        case .inboxTranscript, .graphNode:  return .preferredFont(forTextStyle: .subheadline)
        }
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
        view.font = style.uiFont
        view.textColor = UIColor(WW.ink)
        view.attributedText = NSAttributedString(string: text, attributes: attributes)
        view.typingAttributes = attributes
        view.selectedRange = clamp(selection, to: text as NSString)
        // Focus on the next runloop pass: the view isn't in the window hierarchy yet during make.
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
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
        return [.font: style.uiFont,
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

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.text = text
        controller.textView = view
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
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
    var lineLimit: Int = 1

    var body: some View {
        switch recording.status {
        case .done:
            Text(text)
                .font(.subheadline)
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

    // Move-to-document pane: the recordings being moved (one, from a swipe; or many, from batch).
    @State private var movingIDs: Set<UUID>?

    // Swipe-right Transform: which recording is picking a preset, and which are mid-transform
    // (their rows show a spinner in place of the transcript preview).
    @State private var transformTargetID: UUID?
    @State private var transformingIDs: Set<UUID> = []

    // New-document step: the recordings to drop into a fresh doc, plus its editable title.
    @State private var pendingNewDocIDs: Set<UUID>?
    @State private var newDocTitle = ""

    private var inbox: Document? { model.documents.document(with: documentID) }
    /// Newest first — the Inbox reads as a capture feed, so the clip you just made is at the top.
    private var recordings: [Recording] {
        (inbox?.recordings ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    private var documentTargets: [Document] {
        model.documents.documents.filter { $0.id != documentID && $0.title != DocumentStore.inboxTitle }
    }

    var body: some View {
        List {
            ForEach(recordings) { recording in
                inboxRow(recording)
            }
        }
        .wwList()
        .navigationTitle(selectionMode ? "\(selected.count) selected" : DocumentStore.inboxTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectionMode {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { exitSelection() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected.count == recordings.count ? "Deselect All" : "Select All") { selectAll() }
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
                    WWBatchButton("New", "doc.badge.plus") { startNewDocument(for: selected) }
                    WWBatchButton("Move", "folder") {
                        withAnimation(.snappy(duration: 0.22)) { movingIDs = selected }
                    }
                }
                .disabled(selected.isEmpty)
            } else if editingID == nil {
                CaptureBar(presets: model.documents.presets,
                           selected: model.autoTransformPreset(for: documentID),
                           onSelect: { model.setAutoTransform($0, for: documentID) },
                           onRecord: { showingRecorder = true })
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
            isEditing: isEditing,
            onTapLabel: {
                if selectionMode { toggle(recording.id) } else { startEditing(recording) }
            },
            onLongPress: { enterSelection(with: recording.id) },
            onCopy: { copy(recording) },
            onRetranscribe: { Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) } },
            moveTargets: documentTargets,
            onMove: { target in model.documents.moveRecording(recording.id, from: documentID, to: target.id) }
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
                // Swipe right → Copy / Transform.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
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

    // MARK: Move-to-document pane

    /// Floating pane (swipe a recording left → Move, or batch "Move"): the same design as the
    /// document Transform pane — a dimmed scrim you tap to dismiss, with the pane anchored at the
    /// bottom. Lists the destination documents and, below them, a "New Document" button that opens
    /// the rename step and then moves the recording(s) into the fresh document.
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

    /// The pane body: a "Move to Document" header, one row per destination document, then a
    /// "New Document" row (mirroring "Add New Transform…" on the Transform pane).
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
                    ForEach(documentTargets) { target in
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
                        WWHairline().padding(.leading, 16)
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { movingIDs = nil }
                        startNewDocument(for: ids)
                    } label: {
                        Label("New Document", systemImage: "plus")
                            .foregroundStyle(WW.moss)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    // MARK: New document (from a swipe or a batch selection)

    /// Open the "Rename document" step, pre-filling the title with a suggested name drawn from the
    /// recordings being filed away.
    private func startNewDocument(for ids: Set<UUID>) {
        guard let seed = recordings.first(where: { ids.contains($0.id) }) else { return }
        newDocTitle = suggestedDocumentTitle(for: seed)
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

    private func selectAll() {
        let all = Set(recordings.map(\.id))
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
    let isEditing: Bool
    let onTapLabel: () -> Void
    let onLongPress: () -> Void
    let onCopy: () -> Void
    let onRetranscribe: () -> Void
    let moveTargets: [Document]
    let onMove: (Document) -> Void
    @ViewBuilder var editor: Editor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isSelected ? WW.moss : WW.inkTertiary)
            }

            // Up to an 8-line preview over the capture date/time; tap to edit the transcript (or
            // toggle the row when selecting). While editing, the editor takes the preview's place.
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    editor
                } else if isTransforming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Transforming…").font(.subheadline).foregroundStyle(WW.inkSecondary)
                    }
                } else {
                    RecordingLabel(recording: recording, lineLimit: 8)
                }
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(WW.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(TapUnless(disabled: isEditing, action: onTapLabel))

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

/// Attaches a tap gesture only when `disabled` is false — an open editor needs its taps for the
/// caret, so the gesture has to be absent rather than merely ignored.
private struct TapUnless: ViewModifier {
    let disabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled { content } else { content.onTapGesture(perform: action) }
    }
}

/// The long-press counterpart of `TapUnless`: an open editor keeps its long press for the text
/// view's selection handles rather than entering batch selection.
private struct LongPressUnless: ViewModifier {
    let disabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled { content } else { content.onLongPressGesture(perform: action) }
    }
}

/// Carries whatever the editor's Share button is handing to the system share sheet — the
/// transcript's text or the recording's audio file — through one `.sheet(item:)`.
private struct ShareTarget: Identifiable {
    let id = UUID()
    let items: [Any]
}


// MARK: - Graph documents
//
// The graph canvas lives at the bottom of this file — rather than in one of its own — for the same
// reason the Inbox and the recorder do: `project.yml` globs `Apps/iOS` when the Xcode project is
// *generated*, so a new source file is invisible to an already-generated project until someone
// re-runs xcodegen. Everything below is self-contained; it just rides in on a file the target
// already compiles.

/// A **graph document**: a force-directed mind map on a pannable, zoomable canvas, as opposed to a
/// document's column of paragraphs.
///
/// • **Hold anywhere** on the canvas and a node appears under your finger and starts recording;
///   lift and it stops, transcribes, and the words drop into that node. One gesture, one node.
/// • **Double-tap** the canvas for a node you type into instead.
/// • A node is a small edit block: **tap twice** to edit it in place, **long-press** for the
///   actions a paragraph gets from a swipe, as a dropdown.
/// • **Drag** a node and its children come along; **drop it on another node** and the whole branch
///   hangs off that one instead.
/// • The **"+"** on a node's right edge adds a child; the one midway along a line inserts a node
///   between the two it joins.
///
/// There's no red record button along the bottom — the hold *is* the record button — but the Auto
/// transform toggle is the same one the Inbox and documents carry, and applies to nodes the same
/// way (see `AppModel.captureGraphNode`).
struct GraphDocumentView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    /// Live node positions and the relaxation that produces them. The canvas reads this rather than
    /// the stored positions, which are only written back once the graph settles.
    @StateObject private var layout = GraphLayoutEngine()

    /// The recorder behind hold-to-record. (Revise uses the ordinary `RecordingSheet` instead —
    /// replacing a node deliberately deserves the pause/discard controls.)
    @StateObject private var recorder = AudioRecorder()

    // Canvas transform. `pan` is where the canvas origin sits in view coordinates, `scale` the zoom.
    @State private var pan: CGPoint = .zero
    @State private var panOrigin: CGPoint?
    @State private var scale: CGFloat = 1
    @State private var zoomStart: ZoomStart?
    @State private var canvasSize: CGSize = .zero
    @State private var didPlaceCanvas = false

    // The finger on the bare canvas: pan, hold-to-record, or a tap.
    @State private var phase: CanvasPhase = .idle
    @State private var holdTask: Task<Void, Never>?
    @State private var recordingNodeID: UUID?
    @State private var lastTap: (at: Date, point: CGPoint)?

    // Node editing, in place, in its own card.
    @State private var editingNodeID: UUID?
    @State private var editingText = ""
    @State private var editingSelection = NSRange(location: 0, length: 0)

    // Node interaction: the long-press dropdown, a drag and where it would drop, and the transforms
    // running right now.
    @State private var menuNodeID: UUID?
    @State private var draggingNodeID: UUID?
    @State private var dropTargetID: UUID?
    @State private var transformTargetID: UUID?
    @State private var transformingNodeIDs: Set<UUID> = []
    @State private var reviseTask: ReviseTask?

    /// Measured card sizes, so a drop lands on the node it looks like it lands on and the "+" sits
    /// on the actual edge rather than an assumed one.
    @State private var nodeSizes: [UUID: CGSize] = [:]

    // Title, sharing.
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var shareItem: ShareItem?
    @State private var documentFileShare: DocumentFileShareItem?

    private var document: Document? { model.documents.document(with: documentID) }

    var body: some View {
        Group {
            if let document {
                canvas(for: document)
            } else {
                WWEmptyState(title: "Graph not found", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WW.paper)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(for: document) }
        // The same bottom strip as everywhere else, minus the red dot: on a graph, recording is the
        // hold on the canvas, and it places the node at the same time.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editingNodeID == nil {
                CaptureBar(presets: model.documents.presets,
                           selected: model.autoTransformPreset(for: documentID),
                           onSelect: { model.setAutoTransform($0, for: documentID) },
                           onRecord: nil)
            }
        }
        .onAppear {
            layout.onSettle = { positions in
                model.documents.moveNodes(positions, in: documentID)
            }
        }
        // Leaving commits the open editor and the settled layout, the way leaving a document commits
        // an open paragraph — and closes off a hold that never got its finger back (a gesture the
        // system cancelled, or a screen left mid-recording), which would otherwise leave the
        // recorder running behind a node that says "Recording" forever.
        .onDisappear {
            cancelHold()
            if recordingNodeID != nil { finishHoldRecording() }
            phase = .idle
            finishEditing()
            layout.stop()
        }
        .sheet(item: $reviseTask) { task in
            RecordingSheet(title: "Revise Node",
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                model.captureGraphNode(audioURL: url, duration: duration,
                                       nodeID: task.nodeID, in: documentID)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.text])
        }
        .sheet(item: $documentFileShare) { item in
            ActivityView(activityItems: [item.url])
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
            content(for: document)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(alignment: .topLeading) { GraphGrid(pan: pan, scale: scale) }
                .background(WW.paper)
                .clipped()
                .contentShape(Rectangle())
                // The canvas's own gestures. A touch that lands on a node is the node's — SwiftUI
                // gives a child's gesture priority over its ancestors' — so this only ever sees the
                // bare canvas.
                .gesture(canvasGesture())
                .simultaneousGesture(zoomGesture())
                .overlay(alignment: .topLeading) { menuOverlay(for: document, in: geo.size) }
                .overlay {
                    if document.nodes.isEmpty {
                        WWEmptyState(title: "An empty canvas",
                                     systemImage: "point.3.connected.trianglepath.dotted",
                                     message: "Hold anywhere to record a node — it appears where your finger is and stops when you lift it. Double-tap to type one instead.")
                    }
                }
                .onAppear {
                    canvasSize = geo.size
                    layout.sync(with: document)
                    placeCanvas(in: geo.size, document: document)
                }
                .onChange(of: geo.size) { _, size in canvasSize = size }
                // Nodes added, removed, or re-parented: the layout needs the new shape. Text and
                // positions change constantly and it doesn't care about either.
                .onChange(of: structureKey(of: document)) { _, _ in
                    if let latest = self.document { layout.sync(with: latest) }
                }
        }
    }

    /// Everything drawn in canvas coordinates: the lines, the "+" on each of them, and the nodes.
    /// One transform is applied to the lot — `scaleEffect` then `offset` — so a canvas point `c`
    /// lands at `c * scale + pan` and `canvasPoint(for:)` is its exact inverse.
    @ViewBuilder
    private func content(for document: Document) -> some View {
        let lines = edges(of: document)
        ZStack(alignment: .topLeading) {
            GraphEdgeShape(edges: lines)
                .stroke(WW.inkTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .allowsHitTesting(false)

            ForEach(lines) { edge in
                GraphPlusButton { insertNode(on: edge) }
                    .accessibilityLabel("Insert node between")
                    .position(x: edge.midpoint.x + GraphCanvas.center,
                              y: edge.midpoint.y + GraphCanvas.center)
            }

            ForEach(document.nodes) { node in
                nodeView(node, in: document)
            }
        }
        .frame(width: GraphCanvas.extent, height: GraphCanvas.extent, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: pan.x - GraphCanvas.center * scale, y: pan.y - GraphCanvas.center * scale)
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeView(_ node: GraphNode, in document: Document) -> some View {
        let isEditing = editingNodeID == node.id
        let center = point(of: node.id, in: document)
        let card = nodeCard(node, in: document, isEditing: isEditing)
            // The open editor is given a little more room than a card at rest: it has to hold the
            // text *and* the action row along the bottom of its outline.
            .frame(width: isEditing ? GraphCanvas.editingNodeWidth : GraphCanvas.nodeWidth,
                   alignment: .leading)
            .background { sizeReader(for: node.id) }
            .overlay(alignment: .trailing) {
                if !isEditing {
                    GraphPlusButton { addChild(to: node) }
                        .accessibilityLabel("Add child node")
                        .offset(x: 17)
                }
            }

        Group {
            if isEditing {
                // The open editor keeps every gesture to itself: a double tap selects a word, a long
                // press raises the selection handles, a drag moves the caret.
                card
            } else {
                card
                    .onTapGesture(count: 2) { startEditing(node) }
                    .onLongPressGesture(minimumDuration: 0.45) { openMenu(for: node) }
                    .gesture(nodeDrag(node, in: document))
            }
        }
        .position(x: center.x + GraphCanvas.center, y: center.y + GraphCanvas.center)
        .zIndex(isEditing || draggingNodeID == node.id ? 2 : 1)
    }

    /// A node: the same edit block a paragraph or an Inbox entry becomes, shrunk to a card.
    @ViewBuilder
    private func nodeCard(_ node: GraphNode, in document: Document, isEditing: Bool) -> some View {
        if isEditing {
            WWInlineEditBox(onDone: { finishEditing() }) {
                InlineTextEditor(text: $editingText, selection: $editingSelection, style: .graphNode)
            } actions: {
                WWInlineEditAction("Revise", "mic.fill") { reviseEditingNode() }
                WWInlineEditAction("Transform", "wand.and.stars", enabled: model.modelReady) {
                    transformEditingNode()
                }
            }
        } else {
            nodeLabel(node, in: document)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WW.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(nodeBorder(node), lineWidth: nodeBorderWidth(node)))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }

    /// What a node says while it isn't being edited: its words, or why it hasn't any yet.
    @ViewBuilder
    private func nodeLabel(_ node: GraphNode, in document: Document) -> some View {
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
        } else if transformingNodeIDs.contains(node.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Transforming…").font(.caption).foregroundStyle(WW.inkSecondary)
            }
        } else if node.hasText {
            Text(node.trimmedText)
                .font(.subheadline)
                .foregroundStyle(WW.ink)
                .lineLimit(6)
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

    private func nodeBorder(_ node: GraphNode) -> Color {
        if dropTargetID == node.id { return WW.moss }
        if recordingNodeID == node.id { return WW.ember }
        return WW.hairline
    }

    private func nodeBorderWidth(_ node: GraphNode) -> CGFloat {
        (dropTargetID == node.id || recordingNodeID == node.id) ? 2 : 1
    }

    private func recording(for node: GraphNode, in document: Document) -> Recording? {
        guard let id = node.recordingID else { return nil }
        return document.recordings.first(where: { $0.id == id })
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

    private func edges(of document: Document) -> [GraphEdgeLine] {
        document.nodes.compactMap { node in
            guard let parentID = node.parentID, document.node(with: parentID) != nil else { return nil }
            return GraphEdgeLine(id: node.id,
                                 parentID: parentID,
                                 from: point(of: parentID, in: document),
                                 to: point(of: node.id, in: document))
        }
    }

    /// Where a node is *right now*: the layout's live position while the canvas is open, falling
    /// back to the stored one for a node it hasn't adopted yet.
    private func point(of id: UUID, in document: Document) -> CGPoint {
        if let live = layout.points[id] { return CGPoint(x: live.x, y: live.y) }
        guard let node = document.node(with: id) else { return .zero }
        return CGPoint(x: node.position.x, y: node.position.y)
    }

    /// What the layout needs to be told about: which nodes exist, and what hangs off what.
    private func structureKey(of document: Document) -> String {
        document.nodes
            .map { "\($0.id.uuidString)>\($0.parentID?.uuidString ?? "-")" }
            .sorted()
            .joined(separator: ",")
    }

    // MARK: Canvas gestures (pan · hold to record · double-tap)

    /// What the finger on the bare canvas turned out to be doing.
    private enum CanvasPhase { case idle, pressing, panning, recording }

    private func canvasGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved: CGFloat = hypot(value.translation.width, value.translation.height)
                switch phase {
                case .idle:
                    // Every touch starts out ambiguous: it becomes a pan the moment it moves, a
                    // recording if it stays put long enough, and a tap if it does neither.
                    phase = .pressing
                    panOrigin = pan
                    armHold(at: value.startLocation)
                case .pressing:
                    if moved > GraphCanvas.tapSlop {
                        cancelHold()
                        phase = .panning
                    }
                case .panning, .recording:
                    break
                }
                if phase == .panning, let panOrigin {
                    pan = CGPoint(x: panOrigin.x + value.translation.width,
                                  y: panOrigin.y + value.translation.height)
                }
            }
            .onEnded { value in
                cancelHold()
                let moved: CGFloat = hypot(value.translation.width, value.translation.height)
                switch phase {
                case .recording:
                    finishHoldRecording()
                case .idle, .pressing:
                    if moved <= GraphCanvas.tapSlop { registerTap(at: value.startLocation) }
                case .panning:
                    break
                }
                phase = .idle
                panOrigin = nil
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? ZoomStart(scale: scale, pan: pan, anchor: value.startLocation)
                if zoomStart == nil { zoomStart = start }
                let next = min(max(start.scale * value.magnification,
                                   GraphCanvas.minScale), GraphCanvas.maxScale)
                // Hold the canvas point under the pinch still, so zooming goes where you're looking.
                let focus = CGPoint(x: (start.anchor.x - start.pan.x) / start.scale,
                                    y: (start.anchor.y - start.pan.y) / start.scale)
                pan = CGPoint(x: start.anchor.x - focus.x * next,
                              y: start.anchor.y - focus.y * next)
                scale = next
            }
            .onEnded { _ in zoomStart = nil }
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

    private func armHold(at viewPoint: CGPoint) {
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(GraphCanvas.holdDuration * 1_000_000_000))
            guard !Task.isCancelled, phase == .pressing else { return }
            await beginHoldRecording(at: viewPoint)
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }

    /// The hold has been held: put a node under the finger and start capturing into it.
    @MainActor
    private func beginHoldRecording(at viewPoint: CGPoint) async {
        guard await recorder.requestPermission() else {
            model.setupError = "Microphone permission is required to record."
            return
        }
        // The permission prompt only ever appears once, but the finger may well have lifted while
        // it was up — there's nothing to record into then.
        guard phase == .pressing else { return }
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
        layout.hold(node.id)          // stay under the finger for as long as it's down
        recordingNodeID = node.id
        phase = .recording
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// The finger lifted: stop, file the clip against the node it was spoken into, and transcribe.
    private func finishHoldRecording() {
        guard let nodeID = recordingNodeID else { return }
        recordingNodeID = nil
        layout.hold(nil)
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

    /// Taps on bare canvas: the second of a pair makes a node to type into, a lone one puts away
    /// whatever is open. (Detected here rather than with a tap gesture of its own, which would be
    /// one more recogniser competing with the press this canvas already reads four ways.)
    private func registerTap(at viewPoint: CGPoint) {
        let now = Date()
        let drift: CGFloat = lastTap.map {
            hypot(viewPoint.x - $0.point.x, viewPoint.y - $0.point.y)
        } ?? .greatestFiniteMagnitude
        if let last = lastTap, now.timeIntervalSince(last.at) < GraphCanvas.doubleTapWindow,
           drift < 44 {
            lastTap = nil
            addTypedNode(at: viewPoint)
        } else {
            lastTap = (now, viewPoint)
            finishEditing()
            withAnimation(.snappy(duration: 0.2)) { menuNodeID = nil }
        }
    }

    private func addTypedNode(at viewPoint: CGPoint) {
        let spot = canvasPoint(for: viewPoint)
        let node = GraphNode(position: GraphPoint(x: spot.x, y: spot.y))
        model.documents.addNode(node, to: documentID)
        startEditing(node)
    }

    // MARK: Dragging a node (and its branch)

    private func nodeDrag(_ node: GraphNode, in document: Document) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if draggingNodeID != node.id {
                    draggingNodeID = node.id
                    menuNodeID = nil
                    finishEditing()
                    layout.beginDrag(subtree: document.subtree(of: node.id))
                }
                // Translations are in view points; the canvas is in canvas points.
                layout.drag(by: GraphPoint(x: value.translation.width / scale,
                                           y: value.translation.height / scale))
                dropTargetID = dropTarget(for: node, in: document)
            }
            .onEnded { _ in
                let target = dropTargetID
                dropTargetID = nil
                draggingNodeID = nil
                layout.endDrag()
                if let target,
                   model.documents.reparentNode(node.id, to: target, in: documentID) {
                    let name = document.node(with: target)?.trimmedText ?? ""
                    wwLog("Hung a graph branch under “\(name.isEmpty ? "a node" : name)”", .general)
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                }
                layout.commit()
            }
    }

    /// The node a drop would land on: whichever card the dragged node's centre is over, ignoring
    /// the branch being dragged (a node can't hang off itself, or off its own child).
    private func dropTarget(for node: GraphNode, in document: Document) -> UUID? {
        let center = point(of: node.id, in: document)
        let excluded = Set(document.subtree(of: node.id))
        return document.nodes.first(where: { other in
            guard !excluded.contains(other.id) else { return false }
            return rect(of: other, in: document).contains(center)
        })?.id
    }

    private func rect(of node: GraphNode, in document: Document) -> CGRect {
        let center = point(of: node.id, in: document)
        let size = nodeSizes[node.id] ?? CGSize(width: GraphCanvas.nodeWidth, height: 56)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Adding nodes from the "+" buttons

    /// The store places a child relative to its parent's *stored* position; the canvas is showing
    /// the live one, which can be a beat ahead of it while the graph is still moving. Both of these
    /// re-place the new node against what's actually on screen, before the layout adopts it, so it
    /// appears where the "+" was rather than where the last save left things.
    private func addChild(to parent: GraphNode) {
        guard let node = model.documents.addChildNode(to: parent.id, in: documentID) else { return }
        let live = layout.points[parent.id] ?? parent.position
        model.documents.moveNodes(
            [node.id: GraphPoint(x: live.x + (node.position.x - parent.position.x),
                                 y: live.y + (node.position.y - parent.position.y))],
            in: documentID)
        startEditing(node)
    }

    private func insertNode(on edge: GraphEdgeLine) {
        guard let node = model.documents.insertNode(between: edge.parentID, and: edge.id,
                                                    in: documentID) else { return }
        model.documents.moveNodes([node.id: GraphPoint(x: edge.midpoint.x, y: edge.midpoint.y)],
                                  in: documentID)
        startEditing(node)
    }

    // MARK: Editing a node in place

    private func startEditing(_ node: GraphNode) {
        if editingNodeID != nil { finishEditing() }
        menuNodeID = nil
        let text = node.trimmedText
        editingText = text
        editingSelection = NSRange(location: (text as NSString).length, length: 0)
        // Hold it still while it's open: a card that drifts out from under the keyboard mid-sentence
        // is its own kind of infuriating.
        layout.hold(node.id)
        withAnimation(.snappy(duration: 0.22)) { editingNodeID = node.id }
    }

    /// Done: write the buffer back. A node left with nothing in it — typed into and abandoned — is
    /// removed rather than left on the canvas as a blank card; one that's waiting on a recording, or
    /// holding a branch up, stays.
    private func finishEditing() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        layout.hold(nil)
        model.documents.setNodeText(id, in: documentID, to: editingText)
        guard let document, let node = document.node(with: id) else { return }
        if !node.hasText, node.recordingID == nil, document.children(of: id).isEmpty {
            model.documents.deleteNode(id, in: documentID)
        }
    }

    /// "Revise" from inside the editor: keep what's typed, then record a clip that replaces it.
    private func reviseEditingNode() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        layout.hold(nil)
        model.documents.setNodeText(id, in: documentID, to: editingText)
        reviseTask = ReviseTask(nodeID: id)
    }

    /// "Transform" from inside the editor: flush what's on screen, then pick a preset to run on it.
    private func transformEditingNode() {
        guard let id = editingNodeID else { return }
        editingNodeID = nil
        layout.hold(nil)
        model.documents.setNodeText(id, in: documentID, to: editingText)
        transformTargetID = id
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
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        withAnimation(.snappy(duration: 0.2)) { menuNodeID = node.id }
    }

    /// The actions a paragraph gets from a swipe, as a list under the node they apply to — there's
    /// no row to swipe on a canvas, so the long press opens them here instead.
    private func menuItems(for node: GraphNode) -> [NodeMenuItem] {
        [
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
    }

    @ViewBuilder
    private func menuOverlay(for document: Document, in size: CGSize) -> some View {
        if let id = menuNodeID, let node = document.node(with: id) {
            let items = menuItems(for: node)
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
        let center = point(of: node.id, in: document)
        let view = CGPoint(x: center.x * scale + pan.x, y: center.y * scale + pan.y)
        let cardHeight: CGFloat = (nodeSizes[node.id]?.height ?? 56) * scale
        let margin: CGFloat = 12
        let maxX: CGFloat = max(margin, size.width - GraphCanvas.menuWidth - margin)
        let maxY: CGFloat = max(margin, size.height - height - margin)
        let x: CGFloat = view.x - GraphCanvas.menuWidth / 2
        let y: CGFloat = view.y + cardHeight / 2 + 10
        return CGPoint(x: min(max(margin, x), maxX), y: min(max(margin, y), maxY))
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

    private func recenter() {
        guard let document, canvasSize.width > 0 else { return }
        withAnimation(.snappy(duration: 0.3)) {
            scale = 1
            pan = centeringPan(for: document, in: canvasSize)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(for document: Document?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
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
        if let document {
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                    Divider()
                    Button { recenter() } label: {
                        Label("Center Graph", systemImage: "scope")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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

    /// A pinch in progress, as it stood when it began — the fixed point the zoom is worked out from.
    private struct ZoomStart {
        let scale: CGFloat
        let pan: CGPoint
        let anchor: CGPoint
    }

    /// Drives the `RecordingSheet` that records a node's replacement ("Revise").
    private struct ReviseTask: Identifiable {
        let nodeID: UUID
        var id: UUID { nodeID }
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
    /// A node that's open for editing, which has an action row to fit as well as its text.
    static let editingNodeWidth: CGFloat = 240
    static let menuWidth: CGFloat = 210
    static let gridSpacing: CGFloat = 44

    static let minScale: CGFloat = 0.35
    static let maxScale: CGFloat = 2.5

    /// How long a press has to hold still before it becomes a recording.
    static let holdDuration: TimeInterval = 0.4
    /// A clip shorter than this was a stray press, not something said.
    static let minimumClip: TimeInterval = 0.3
    /// How far a touch may drift and still count as a press rather than a pan.
    static let tapSlop: CGFloat = 12
    static let doubleTapWindow: TimeInterval = 0.35
}

// MARK: - Edges

/// One parent→child line, in canvas coordinates. Named by the child, since that's the node the edge
/// belongs to: insert a node "on" this edge and the child is what it adopts.
struct GraphEdgeLine: Identifiable {
    let id: UUID
    let parentID: UUID
    let from: CGPoint
    let to: CGPoint

    var midpoint: CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
}

/// Every edge as one stroked path — cheaper than a view per line, and it can't get out of step with
/// the nodes because both read the same live positions.
private struct GraphEdgeShape: Shape {
    let edges: [GraphEdgeLine]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            path.move(to: CGPoint(x: edge.from.x + GraphCanvas.center,
                                  y: edge.from.y + GraphCanvas.center))
            path.addLine(to: CGPoint(x: edge.to.x + GraphCanvas.center,
                                     y: edge.to.y + GraphCanvas.center))
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

// MARK: - The "+" button

/// The small "+" that hangs off a node's right edge (add a child) and sits midway along each line
/// (insert a node between the two it joins). One control, two places, so both read as the same
/// "put something here".
private struct GraphPlusButton: View {
    var diameter: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WW.moss)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(WW.surface))
                .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layout engine

/// Runs `GraphLayout` for an open canvas: holds the live positions, steps the simulation until the
/// graph settles, and writes the settled positions back through `onSettle`.
///
/// Positions are deliberately *not* stored on every frame — a relaxing graph would otherwise rewrite
/// the document (and its Markdown backup) sixty times a second. They're written when the graph comes
/// to rest, when a drag ends, and when the canvas closes.
@MainActor
final class GraphLayoutEngine: ObservableObject {
    /// Where every node is right now. The canvas reads this rather than the stored positions.
    @Published private(set) var points: [UUID: GraphPoint] = [:]

    /// Called with the positions worth keeping, once the graph has stopped moving.
    var onSettle: (([UUID: GraphPoint]) -> Void)?

    private var bodies: [GraphLayout.Body] = []
    private var pinned: Set<UUID> = []
    private var held: UUID?
    private var dragOrigins: [UUID: GraphPoint] = [:]
    private var timer: Timer?
    private var frames = 0

    private let frameInterval: TimeInterval = 1.0 / 30
    private let settledDistance: Double = 0.2
    /// A graph that won't settle stops after this many steps rather than spinning forever.
    private let maxFrames = 600

    /// Adopt the document's nodes: new ones arrive at their stored position, familiar ones keep the
    /// position the simulation has them at. Any change to the shape of the graph starts it moving.
    func sync(with document: Document) {
        var next: [GraphLayout.Body] = []
        var changed = bodies.count != document.nodes.count
        for node in document.nodes {
            let existing = bodies.first { $0.id == node.id }
            if existing == nil || existing?.parentID != node.parentID { changed = true }
            next.append(GraphLayout.Body(
                id: node.id,
                parentID: node.parentID,
                position: existing?.position ?? node.position,
                // Only roots are anchored, and only to where they were put — a child hangs wherever
                // its springs leave it.
                home: node.parentID == nil ? (existing?.home ?? node.position) : nil,
                isPinned: isFrozen(node.id)))
        }
        bodies = next
        publish()
        if changed { start() }
    }

    /// Hold one node exactly where it is — the one being edited, or the one being recorded into. A
    /// card shouldn't wander out from under the keyboard while you're typing into it, or away from
    /// the finger that's holding it down. Pass nil to let it go.
    func hold(_ id: UUID?) {
        guard held != id else { return }
        held = id
        for index in bodies.indices { bodies[index].isPinned = isFrozen(bodies[index].id) }
        start()
    }

    /// Nodes the simulation may not move: the branch under a drag, and the held node.
    private func isFrozen(_ id: UUID) -> Bool { pinned.contains(id) || held == id }

    // MARK: Dragging

    /// Pin a branch under the user's finger. It stops being moved by the simulation, but keeps
    /// pushing everything else around — so the rest of the graph makes room as it's dragged through.
    func beginDrag(subtree ids: [UUID]) {
        pinned = Set(ids)
        dragOrigins = [:]
        for index in bodies.indices {
            bodies[index].isPinned = isFrozen(bodies[index].id)
            guard pinned.contains(bodies[index].id) else { continue }
            dragOrigins[bodies[index].id] = bodies[index].position
        }
        start()
    }

    /// Move the pinned branch to `delta` from where it was when the drag began. (Cumulative, not
    /// incremental: it's the gesture's own translation, so nothing drifts.)
    func drag(by delta: GraphPoint) {
        for index in bodies.indices {
            guard let origin = dragOrigins[bodies[index].id] else { continue }
            bodies[index].position = GraphPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        }
        publish()
    }

    func endDrag() {
        for index in bodies.indices where pinned.contains(bodies[index].id) {
            // A root dropped somewhere new wants to stay there, so that's its home from now on.
            if bodies[index].parentID == nil { bodies[index].home = bodies[index].position }
        }
        pinned = []
        for index in bodies.indices { bodies[index].isPinned = isFrozen(bodies[index].id) }
        dragOrigins = [:]
        publish()
        start()
    }

    // MARK: The loop

    func start() {
        frames = 0
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stop stepping, and write the positions back.
    func stop() {
        timer?.invalidate()
        timer = nil
        commit()
    }

    func commit() {
        guard !points.isEmpty else { return }
        onSettle?(points)
    }

    private func tick() {
        let next = GraphLayout.step(bodies)
        let moved = GraphLayout.maxDisplacement(from: bodies, to: next)
        bodies = next
        publish()
        frames += 1
        // A drag keeps it running however still the graph looks: the branch under the finger is
        // pinned, so "nothing moved" says nothing about whether the gesture is over.
        if (moved < settledDistance && pinned.isEmpty) || frames >= maxFrames { stop() }
    }

    private func publish() {
        var next: [UUID: GraphPoint] = [:]
        next.reserveCapacity(bodies.count)
        for body in bodies { next[body.id] = body.position }
        points = next
    }
}
