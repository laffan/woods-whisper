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

    // Paragraph editing
    @State private var editingParagraph: Document.Paragraph?

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
        .onDisappear { playback.stop() }
        .sheet(item: $recorderTask) { task in
            RecordingSheet(title: task.sheetTitle,
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                complete(task, url: url, duration: duration)
            }
        }
        .sheet(item: $editingParagraph) { para in
            ParagraphEditorSheet(
                initialText: para.text,
                modelReady: model.modelReady,
                onSave: { text in
                    // Blank lines added while editing split into separate sections.
                    model.documents.replaceParagraph(para.id, in: documentID, withTextSplitInto: text)
                },
                onRevise: {
                    editingParagraph = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        recorderTask = .revise(paragraphID: para.id)
                    }
                },
                onTransform: {
                    editingParagraph = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(.snappy(duration: 0.22)) { paragraphTransformTarget = para.id }
                    }
                },
                onInsert: { text, caret in
                    editingParagraph = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        recorderTask = .insertAtCaret(paragraphID: para.id, caret: caret, baseText: text)
                    }
                }
            )
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
                    recorderTask = .insertBody(at: 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                if !editMode.isEditing {
                    InsertHereButton(isRecording: recorderTask == .insertBody(at: 0)) {
                        recorderTask = .insertBody(at: 0)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
                ForEach(document.paragraphs) { para in
                    let position = (document.paragraphs.firstIndex(of: para) ?? 0) + 1
                    VStack(alignment: .leading, spacing: 10) {
                        paragraphContent(para)
                        if !editMode.isEditing {
                            InsertHereButton(isRecording: recorderTask == .insertBody(at: position)) {
                                recorderTask = .insertBody(at: position)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
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

    @ViewBuilder
    private func paragraphContent(_ para: Document.Paragraph) -> some View {
        if transformingParagraphID == para.id {
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
            ToolbarItem(placement: .primaryAction) {
                Button { recorderTask = .addToRecordings } label: {
                    Label("Add Recording", systemImage: "mic.badge.plus")
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

    // MARK: Paragraph editing

    private func startEditing(_ para: Document.Paragraph) {
        editingParagraph = para
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
        .padding(.vertical, 4)
    }

    private var rule: some View {
        Rectangle().fill(WW.hairline).frame(height: 1).frame(maxWidth: .infinity)
    }
}

// MARK: - Text editor sheet

/// A full-screen text editor used for editing a single paragraph, the whole document, or a
/// document from the list. An optional `accessory` is pinned below the editor (used by the
/// paragraph editor to offer Revise / Transform).
struct TextEditorSheet<Accessory: View>: View {
    let title: String
    @Binding var text: String
    let onSave: () -> Void
    @ViewBuilder var accessory: () -> Accessory
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
                accessory()
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

extension TextEditorSheet where Accessory == EmptyView {
    init(title: String, text: Binding<String>, onSave: @escaping () -> Void) {
        self.init(title: title, text: text, onSave: onSave) { EmptyView() }
    }
}

// MARK: - Paragraph editor (caret-aware, with Insert)

/// The single-paragraph editor. Unlike the generic `TextEditorSheet` it tracks the caret (via a
/// `UITextView`) so the "Insert" action can record a clip, transcribe it, and splice the text in at
/// the cursor. Also offers Revise (re-record the whole paragraph) and Transform.
///
/// It owns its own text/selection state, seeded from the paragraph; the parent is handed the final
/// text on Save, or — for Insert — the current text and caret offset so it can splice after the
/// recording finishes. Lives here so the app target picks it up without an xcodegen regen.
struct ParagraphEditorSheet: View {
    let modelReady: Bool
    let onSave: (String) -> Void
    let onRevise: () -> Void
    let onTransform: () -> Void
    /// Called with the current text and caret offset; the parent starts the record→transcribe→splice
    /// flow (this sheet dismisses first).
    let onInsert: (_ text: String, _ caret: Int) -> Void

    @State private var text: String
    @State private var selection: NSRange
    @Environment(\.dismiss) private var dismiss

    init(initialText: String,
         modelReady: Bool,
         onSave: @escaping (String) -> Void,
         onRevise: @escaping () -> Void,
         onTransform: @escaping () -> Void,
         onInsert: @escaping (_ text: String, _ caret: Int) -> Void) {
        self.modelReady = modelReady
        self.onSave = onSave
        self.onRevise = onRevise
        self.onTransform = onTransform
        self.onInsert = onInsert
        _text = State(initialValue: initialText)
        _selection = State(initialValue: NSRange(location: (initialText as NSString).length, length: 0))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if canImport(UIKit)
                CaretTrackingTextEditor(text: $text, selection: $selection)
                    .padding(8)
                #else
                TextEditor(text: $text).padding()
                #endif
                WWHairline()
                HStack(spacing: 0) {
                    editorAction("Revise", "mic.fill") { onRevise() }
                    editorAction("Insert", "text.insert") {
                        onInsert(text, selection.location)
                    }
                    editorAction("Transform", "wand.and.stars") { onTransform() }
                        .disabled(!modelReady)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
            .background(WW.paper)
            .navigationTitle("Edit Paragraph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text); dismiss() }
                }
            }
        }
    }

    private func editorAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
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
}

#if canImport(UIKit)
/// A thin `UITextView` wrapper that surfaces the caret/selection so text can be spliced in at the
/// cursor. Two-way bindings keep `text` and `selection` in sync with the view.
struct CaretTrackingTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        let clamped = clamp(selection, to: uiView.text as NSString)
        if uiView.selectedRange != clamped { uiView.selectedRange = clamped }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func clamp(_ range: NSRange, to text: NSString) -> NSRange {
        let loc = max(0, min(range.location, text.length))
        let len = max(0, min(range.length, text.length - loc))
        return NSRange(location: loc, length: len)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CaretTrackingTextEditor
        init(_ parent: CaretTrackingTextEditor) { self.parent = parent }

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
/// document. Newest capture first. Tapping a row opens its transcript editor; swipe left for
/// Move / Delete, right for Copy / Transform. Lives here so the app target picks it up without an
/// xcodegen regen.
struct InboxView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    @State private var showingRecorder = false
    @State private var editingRecording: Recording?

    // "Import Text File…" from the toolbar menu beside the mic
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
                InboxRecordingRow(
                    recording: recording,
                    selectionMode: selectionMode,
                    isSelected: selected.contains(recording.id),
                    isTransforming: transformingIDs.contains(recording.id),
                    onTapLabel: {
                        if selectionMode { toggle(recording.id) } else { editingRecording = recording }
                    },
                    onLongPress: { enterSelection(with: recording.id) },
                    onCopy: { copy(recording) },
                    onRetranscribe: { Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) } },
                    moveTargets: documentTargets,
                    onMove: { target in model.documents.moveRecording(recording.id, from: documentID, to: target.id) }
                )
                .wwRow()
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
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
                // The same import menu the documents carry, sitting beside the mic: the Inbox takes
                // text you already have as readily as it takes something you said.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        TextImportItems(onClipboard: importFromClipboard,
                                        onFile: { showingTextImporter = true })
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Import Text")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingRecorder = true } label: { Image(systemName: "mic.badge.plus") }
                        .accessibilityLabel("New Recording")
                }
            }
        }
        .fileImporter(isPresented: $showingTextImporter,
                      allowedContentTypes: TextImportItems.contentTypes,
                      onCompletion: importTextFile)
        .safeAreaInset(edge: .bottom) {
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
            }
        }
        .overlay {
            if recordings.isEmpty {
                WWEmptyState(title: "Inbox is empty",
                             systemImage: "tray",
                             message: "Recordings from your Watch and the mic button land here — as does text you import.")
            }
        }
        .sheet(isPresented: $showingRecorder) {
            RecordingSheet(title: "New Recording",
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                model.addDeviceRecording(audioURL: url, duration: duration, toDocument: documentID)
            }
        }
        .sheet(item: $editingRecording) { recording in
            InboxTranscriptEditor(model: model, recording: recording, documentID: documentID)
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
private struct InboxRecordingRow: View {
    let recording: Recording
    let selectionMode: Bool
    let isSelected: Bool
    let isTransforming: Bool
    let onTapLabel: () -> Void
    let onLongPress: () -> Void
    let onCopy: () -> Void
    let onRetranscribe: () -> Void
    let moveTargets: [Document]
    let onMove: (Document) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isSelected ? WW.moss : WW.inkTertiary)
            }

            // Up to an 8-line preview over the capture date/time; tap to edit the transcript (or
            // toggle the row when selecting).
            VStack(alignment: .leading, spacing: 4) {
                if isTransforming {
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
            .onTapGesture { onTapLabel() }

            if !selectionMode {
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
        .onLongPressGesture { onLongPress() }
    }
}

/// Carries whatever the editor's Share button is handing to the system share sheet — the
/// transcript's text or the recording's audio file — through one `.sheet(item:)`.
private struct ShareTarget: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// The transcript editor for a single Inbox recording — what tapping a row opens. The text is
/// editable straight away (the same full-screen editor, find/replace and all, that documents use)
/// with Copy / Share / Transform / Reset pinned below it. Share offers either the text or the
/// audio clip, which is also the Inbox's only route to the recording itself now that the rows
/// carry no play control.
///
/// Transform and Reset write through the store rather than the editor's buffer, so each one flushes
/// the text as it stands, runs, then re-seeds the editor from the recording.
private struct InboxTranscriptEditor: View {
    @ObservedObject private var model: AppModel
    private let recordingID: UUID
    private let documentID: UUID

    @State private var text: String
    @State private var working = false
    @State private var showingTransform = false
    @State private var showingShareChoice = false
    @State private var shareTarget: ShareTarget?

    init(model: AppModel, recording: Recording, documentID: UUID) {
        _model = ObservedObject(wrappedValue: model)
        self.recordingID = recording.id
        self.documentID = documentID
        _text = State(initialValue: recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Looked up live so transform/reset results can be read back.
    private var recording: Recording? {
        model.documents.document(with: documentID)?.recordings.first { $0.id == recordingID }
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// An entry that came in as text rather than as a clip: there's no audio to share and no
    /// original transcription to reset back to.
    private var isTextOnly: Bool { recording?.isTextOnly ?? false }

    var body: some View {
        TextEditorSheet(title: "Edit Transcript", text: $text, onSave: { persist() }) {
            VStack(spacing: 0) {
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.caption).foregroundStyle(WW.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                }
                WWHairline()
                HStack(spacing: 0) {
                    actionButton("Copy", "doc.on.doc") { copy() }
                        .disabled(working || isEmpty)
                    // With no clip behind it there's no choice to offer — Share goes straight to
                    // the words.
                    actionButton("Share", "square.and.arrow.up") {
                        if isTextOnly { shareTarget = ShareTarget(items: [text]) }
                        else { showingShareChoice = true }
                    }
                    .disabled(working || (isTextOnly && isEmpty))
                    actionButton("Transform", "wand.and.stars") { showingTransform = true }
                        .disabled(!model.modelReady || working || isEmpty)
                    actionButton("Reset", "arrow.uturn.backward") { reset() }
                        .disabled(working || isTextOnly)
                }
                .padding(.vertical, 8).padding(.horizontal, 8)
            }
        }
        .confirmationDialog("Transform — \(AppSettings.shared.model.shortName)",
                            isPresented: $showingTransform, titleVisibility: .visible) {
            ForEach(model.documents.presets) { preset in
                Button(preset.name) { transform(preset) }
            }
        }
        // Share the words or the audio. "Text" is offered only once there's something to send.
        .confirmationDialog("Share", isPresented: $showingShareChoice, titleVisibility: .visible) {
            if !isEmpty {
                Button("Text") { shareTarget = ShareTarget(items: [text]) }
            }
            Button("Audio Recording") { shareAudio() }
        }
        .sheet(item: $shareTarget) { target in
            ActivityView(activityItems: target.items)
        }
    }

    /// Persist the editor's text back onto the recording.
    private func persist() {
        guard var recording else { return }
        recording.transcript = text
        model.documents.updateRecording(recording, inDocument: documentID)
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
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

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        wwLog("Copied transcript of “\(recording?.name ?? "recording")”", .general)
    }

    /// Hand the clip's audio file to the share sheet, reporting the missing-file case rather than
    /// opening a share sheet on a URL that points at nothing.
    private func shareAudio() {
        guard let recording else { return }
        let url = model.documents.audioURL(for: recording)
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.setupError = "Couldn't share the audio: the recording file is missing."
            return
        }
        shareTarget = ShareTarget(items: [url])
    }

    /// Transform what's on screen: flush the edits first so the preset runs against them, not the
    /// last-saved transcript.
    private func transform(_ preset: PromptPreset) {
        persist()
        working = true
        Task {
            await model.transformRecordingTranscript(preset, recordingID: recordingID, in: documentID)
            text = recording?.transcript ?? text
            working = false
        }
    }

    /// Re-run speech-to-text on the audio to restore the original transcription, discarding edits.
    private func reset() {
        working = true
        Task {
            await model.transcribe(recordingID: recordingID, inDocument: documentID)
            text = recording?.transcript ?? text
            working = false
        }
    }
}
