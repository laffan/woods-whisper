import SwiftUI
import AVFoundation
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

    // Document rename (tap the title)
    @State private var showingRename = false
    @State private var renameText = ""

    // Reset-with-originals confirmation
    @State private var showingResetConfirm = false

    // Inline "Add New Transform" (save a preset and run it at once)
    @State private var creatingTransform: PromptPreset?

    // Recording flows (insert / replace / re-record / add) routed through one sheet
    @State private var recorderTask: RecorderTask?

    // Playback
    @StateObject private var playback = AudioPlaybackController()

    private var document: Document? { model.documents.document(with: documentID) }

    var body: some View {
        Group {
            if let document {
                content(for: document)
            } else {
                ContentUnavailableView("Document not found", systemImage: "doc")
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
                    .font(.callout).foregroundStyle(.secondary)
                InsertHereButton(isRecording: recorderTask == .insertBody(at: 0)) {
                    recorderTask = .insertBody(at: 0)
                }
                .listRowSeparator(.hidden)
            } else {
                if !editMode.isEditing {
                    InsertHereButton(isRecording: recorderTask == .insertBody(at: 0)) {
                        recorderTask = .insertBody(at: 0)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                ForEach(document.paragraphs) { para in
                    let position = (document.paragraphs.firstIndex(of: para) ?? 0) + 1
                    VStack(alignment: .leading, spacing: 6) {
                        paragraphContent(para)
                        if !editMode.isEditing {
                            InsertHereButton(isRecording: recorderTask == .insertBody(at: position)) {
                                recorderTask = .insertBody(at: position)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
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
                        Button("Revise") { recorderTask = .revise(paragraphID: para.id) }.tint(.orange)
                    }
                    // Swipe right → Transform / Edit
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button("Transform") {
                            withAnimation(.snappy(duration: 0.22)) { paragraphTransformTarget = para.id }
                        }.tint(.purple)
                        Button("Edit") { startEditing(para) }.tint(.blue)
                    }
                }
                .onMove { offsets, destination in
                    model.documents.moveParagraphs(in: documentID, from: offsets, to: destination)
                }

                // Breathing room below the document body.
                Color.clear
                    .frame(height: 28)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    @ViewBuilder
    private func paragraphContent(_ para: Document.Paragraph) -> some View {
        if transformingParagraphID == para.id {
            HStack(spacing: 8) { ProgressView(); Text("Transforming…").foregroundStyle(.secondary) }
        } else {
            Text(para.text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Document actions (Copy / Share / Edit)

    @ViewBuilder
    private func documentActionsSection(for document: Document) -> some View {
        if document.hasBodyText {
            Section {
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
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }
        }
    }

    private func docActionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    // MARK: Recordings section

    @ViewBuilder
    private func recordingsSection(for document: Document) -> some View {
        let originals = document.recordings.filter { !$0.isRevision }
        let revisions = document.recordings.filter { $0.isRevision }

        if !originals.isEmpty {
            Section("Recordings") {
                ForEach(originals) { recordingRow($0) }
                .onMove { offsets, destination in
                    model.documents.moveRecordings(in: documentID, isRevision: false,
                                                   from: offsets, to: destination)
                }
            }
        }

        if !revisions.isEmpty {
            Section("Revisions") {
                ForEach(revisions) { recordingRow($0) }
                .onMove { offsets, destination in
                    model.documents.moveRecordings(in: documentID, isRevision: true,
                                                   from: offsets, to: destination)
                }
            }
        }

        if !document.recordings.isEmpty {
            if document.recordings.contains(where: { $0.transcript?.isEmpty == false }) {
                Section {
                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Label("Reset with Originals", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Replaces the document body with the recordings' original transcripts, discarding edits and transforms.")
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
        .onLongPressGesture { withAnimation { editMode = .active } }
        // Swipe left → Delete / Share the audio file
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", role: .destructive) {
                model.documents.deleteRecording(recording.id, fromDocument: documentID)
            }
            Button("Share") {
                audioShareItem = AudioShareItem(url: model.documents.audioURL(for: recording))
            }.tint(.indigo)
        }
        // Swipe right → Transcribe (re-run STT) / Append its transcript to the body / Move
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("Transcribe") {
                Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) }
            }.tint(.blue)
            Button("Append") {
                model.appendRecordingToBody(recordingID: recording.id, in: documentID)
            }.tint(.green)
            if !otherDocuments.isEmpty {
                Button("Move") { movingRecording = recording }.tint(.orange)
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
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }

        if editMode.isEditing {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { withAnimation { editMode = .inactive } }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button { recorderTask = .addToRecordings } label: {
                    Label("Add Recording", systemImage: "mic.badge.plus")
                }
            }
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
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy(duration: 0.22)) { dismiss() } }
            transformPane(editing: editing, dismiss: dismiss, run: run)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.documents.presets) { preset in
                        transformRow(preset, editing: editing, run: run)
                        Divider().padding(.leading, 16)
                    }
                    if editing {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { dismiss() }
                            creatingTransform = PromptPreset(name: "", template: PromptPreset.transcriptToken)
                        } label: {
                            Label("Add New Transform…", systemImage: "plus")
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
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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

// MARK: - Insert-here button

/// A minimal "insert here" affordance: a thin rule across the row with a small + at its center.
/// While a recording is being captured for this slot it turns into a red dot.
private struct InsertHereButton: View {
    var isRecording: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                rule
                Image(systemName: isRecording ? "circle.fill" : "plus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isRecording ? Color.red : Color(.tertiaryLabel))
                rule
            }
        }
        .buttonStyle(.plain)
        .disabled(isRecording)
        .padding(.vertical, 2)
    }

    private var rule: some View {
        Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: .infinity)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .padding()
                accessory()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
                Divider()
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
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
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
            Button(action: onPlay) {
                Image(systemName: (isActive && !isPaused) ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            RecordingLabel(recording: recording)

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
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
            Text(text).lineLimit(lineLimit)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Transcribing…").foregroundStyle(.secondary).lineLimit(1)
            }
        case .pending:
            Text("Waiting to transcribe").foregroundStyle(.secondary).lineLimit(1)
        case .failed:
            Text("Transcription failed").foregroundStyle(.orange).lineLimit(1)
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
/// elapsed-time counter and a live gain meter, and offers two equal-size controls — pause/continue
/// and stop. Stop hands the finished clip back via `onComplete`; swiping it down discards the clip.
/// Lives here (not a standalone file) so the app target picks it up without an xcodegen regen.
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
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(recorder.isPaused ? .secondary : .primary)

                LevelMeter(level: recorder.currentLevel)

                HStack(spacing: 12) {
                    Button { cancel() } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .accessibilityLabel("Cancel")

                    Button { finish() } label: {
                        Image(systemName: "stop.fill")
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("Stop")

                    Button {
                        if recorder.isPaused {
                            recorder.resume(); live.setPaused(false)
                        } else {
                            recorder.pause(); live.setPaused(true)
                        }
                    } label: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!recorder.isRecording)
                    .accessibilityLabel(recorder.isPaused ? "Continue" : "Pause")
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: liveEnabled ? .top : .center)
        }
        .presentationDetents([liveEnabled ? .large : .height(210)])
        .interactiveDismissDisabled(true)
        .task { await begin() }
        .onDisappear { discardIfUnfinished() }
        .alert("Couldn't record", isPresented: Binding(get: { errorMessage != nil },
                                                       set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { dismiss() }
        } message: { Text(errorMessage ?? "") }
    }

    /// Scrolling live transcript of the clip-so-far, shown above the record controls when the
    /// setting is on. Re-transcribed roughly once a second by `LiveTranscriber`. `boxHeight` sizes
    /// the scroll area (≈75% of the sheet).
    private func livePanel(boxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Live Transcription", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
                if live.isProcessing { ProgressView().controlSize(.mini) }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(live.text.isEmpty ? "Listening…" : live.text)
                        .font(.system(size: 19))
                        .foregroundStyle(live.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("liveTextEnd")
                }
                .onChange(of: live.text) { _, _ in
                    withAnimation { proxy.scrollTo("liveTextEnd", anchor: .bottom) }
                }
            }
            .frame(height: boxHeight)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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
            // Live transcription runs a second, in-memory capture alongside the recorder.
            if liveEnabled { live.start(using: model.transcription) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        live.stop()
        guard let result = recorder.stop() else { dismiss(); return }
        didComplete = true
        onComplete(result.url, result.duration)
        dismiss()
    }

    /// Swiped away without stopping: drop the in-progress clip.
    private func discardIfUnfinished() {
        live.stop()
        guard !didComplete else { return }
        _ = recorder.stop()
        if let url = startedURL { try? FileManager.default.removeItem(at: url) }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Inbox

/// The Inbox: a flat list of recordings (Watch clips and "New Recording" captures), not a
/// document. Each recording can be played, copied, moved into a document, re-transcribed, or
/// deleted. Lives here so the app target picks it up without an xcodegen regen.
struct InboxView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    @StateObject private var playback = AudioPlaybackController()
    @State private var showingRecorder = false
    @State private var detailRecording: Recording?

    // Long-press-to-select (the Inbox's own batch mode).
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []

    // Move-to-document pane: the recordings being moved (one, from a swipe; or many, from batch).
    @State private var movingIDs: Set<UUID>?

    // New-document step: the recordings to drop into a fresh doc, plus its editable title.
    @State private var pendingNewDocIDs: Set<UUID>?
    @State private var newDocTitle = ""

    private var inbox: Document? { model.documents.document(with: documentID) }
    private var recordings: [Recording] { inbox?.recordings ?? [] }
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
                    isActive: playback.playingID == recording.id,
                    isPaused: playback.isPaused,
                    onPlay: { playback.toggle(recording, url: model.documents.audioURL(for: recording)) },
                    onTapLabel: {
                        if selectionMode { toggle(recording.id) } else { detailRecording = recording }
                    },
                    onLongPress: { enterSelection(with: recording.id) },
                    onCopy: { copy(recording) },
                    onRetranscribe: { Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) } },
                    moveTargets: documentTargets,
                    onMove: { target in model.documents.moveRecording(recording.id, from: documentID, to: target.id) }
                )
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) {
                        model.documents.deleteRecording(recording.id, fromDocument: documentID)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("Move") { withAnimation(.snappy(duration: 0.22)) { movingIDs = [recording.id] } }
                        .tint(.blue)
                }
            }
        }
        .navigationTitle(selectionMode ? "\(selected.count) selected" : DocumentStore.inboxTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectionMode {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { exitSelection() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selected.count == recordings.count ? "Deselect All" : "Select All") { selectAll() }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingRecorder = true } label: { Image(systemName: "mic.badge.plus") }
                        .accessibilityLabel("New Recording")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionMode {
                HStack(spacing: 16) {
                    batchButton("Delete", "trash", role: .destructive) {
                        model.documents.deleteRecordings(selected, fromDocument: documentID)
                        exitSelection()
                    }
                    batchButton("Copy", "doc.on.doc") { copySelected() }
                    batchButton("New", "doc.badge.plus") { startNewDocument(for: selected) }
                    batchButton("Move", "folder") {
                        withAnimation(.snappy(duration: 0.22)) { movingIDs = selected }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.bar)
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView("Inbox is empty", systemImage: "tray",
                                       description: Text("Recordings from your Watch and the mic button land here."))
            }
        }
        .onAppear { playback.onError = { message in model.setupError = message } }
        .onDisappear { playback.stop() }
        .sheet(isPresented: $showingRecorder) {
            RecordingSheet(title: "New Recording",
                           makeURL: { model.documents.newAudioURL().url }) { url, duration in
                model.addDeviceRecording(audioURL: url, duration: duration, toDocument: documentID)
            }
        }
        .sheet(item: $detailRecording) { recording in
            TranscriptDetailView(model: model, recordingID: recording.id, documentID: documentID)
        }
        .overlay {
            if let ids = movingIDs {
                moveOverlay(ids: ids)
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

    // MARK: Move-to-document pane

    /// Floating pane (swipe a recording right → Move, or batch "Move"): the same design as the
    /// document Transform pane — a dimmed scrim you tap to dismiss, with the pane anchored at the
    /// bottom. Lists the destination documents and, below them, a "New Document" button that opens
    /// the rename step and then moves the recording(s) into the fresh document.
    @ViewBuilder
    private func moveOverlay(ids: Set<UUID>) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy(duration: 0.22)) { movingIDs = nil } }
            movePane(ids: ids)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            Divider()
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { movingIDs = nil }
                        startNewDocument(for: ids)
                    } label: {
                        Label("New Document", systemImage: "plus")
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
        playback.stop()
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

    private func batchButton(_ title: String, _ icon: String,
                             role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(selected.isEmpty)
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

    private func copy(_ recording: Recording) {
        #if canImport(UIKit)
        UIPasteboard.general.string = recording.transcript
        #endif
        wwLog("Copied transcript of “\(recording.name)”", .general)
    }
}

private struct InboxRecordingRow: View {
    let recording: Recording
    let selectionMode: Bool
    let isSelected: Bool
    let isActive: Bool
    let isPaused: Bool
    let onPlay: () -> Void
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
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            } else {
                Button(action: onPlay) {
                    Image(systemName: (isActive && !isPaused) ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            // Up to an 8-line preview; tap to read the full transcript (or toggle when selecting).
            RecordingLabel(recording: recording, lineLimit: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTapLabel() }

            if !selectionMode {
                Menu {
                    Button("Retranscribe", systemImage: "arrow.clockwise", action: onRetranscribe)
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
                    Image(systemName: "ellipsis").foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onLongPressGesture { onLongPress() }
    }
}

/// Full-transcript reader/editor for a single Inbox recording, shown when a preview row is tapped.
/// Offers Transform (rewrite the transcript in place with a preset) and Reset (re-transcribe the
/// audio, restoring the original transcription).
private struct TranscriptDetailView: View {
    @ObservedObject var model: AppModel
    let recordingID: UUID
    let documentID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var showingTransform = false

    /// Looked up live so the view reflects transform/reset edits.
    private var recording: Recording? {
        model.documents.document(with: documentID)?.recordings.first { $0.id == recordingID }
    }

    private var transcript: String {
        recording?.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    Text(transcript.isEmpty ? "(no speech detected)" : transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                Divider()
                HStack(spacing: 0) {
                    actionButton("Transform", "wand.and.stars") { showingTransform = true }
                        .disabled(!model.modelReady || working || transcript.isEmpty)
                    actionButton("Reset", "arrow.uturn.backward") { reset() }
                        .disabled(working)
                }
                .padding(.vertical, 8).padding(.horizontal, 8)
            }
            .overlay(alignment: .top) {
                if working { BusyBanner(message: "Working…").padding(.top, 8) }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Transform — \(AppSettings.shared.model.shortName)",
                                isPresented: $showingTransform, titleVisibility: .visible) {
                ForEach(model.documents.presets) { preset in
                    Button(preset.name) { transform(preset) }
                }
            }
        }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    private func transform(_ preset: PromptPreset) {
        working = true
        Task {
            await model.transformRecordingTranscript(preset, recordingID: recordingID, in: documentID)
            working = false
        }
    }

    /// Re-run speech-to-text on the audio to restore the original transcription.
    private func reset() {
        working = true
        Task {
            await model.transcribe(recordingID: recordingID, inDocument: documentID)
            working = false
        }
    }
}
