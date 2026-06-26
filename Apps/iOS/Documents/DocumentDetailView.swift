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
///   at that spot. Swipe a paragraph for Delete / Replace / Edit / Transform; long-press to enter
///   reorder mode and drag to rearrange.
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
    @State private var showingDocTransform = false
    @State private var paragraphTransformTarget: UUID?
    @State private var isTransformingDoc = false
    @State private var transformingParagraphID: UUID?

    // Paragraph editing
    @State private var editingParagraph: Document.Paragraph?
    @State private var editingText = ""

    // Whole-document editing (the "Edit" action)
    @State private var showingDocEditor = false
    @State private var docEditorText = ""

    // Share
    @State private var shareItem: ShareItem?

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
            TextEditorSheet(title: "Edit Paragraph", text: $editingText) {
                // Blank lines added while editing split into separate sections.
                model.documents.replaceParagraph(para.id, in: documentID, withTextSplitInto: editingText)
            }
        }
        .sheet(isPresented: $showingDocEditor) {
            TextEditorSheet(title: "Edit Document", text: $docEditorText) {
                model.documents.setParagraphs(Document.paragraphs(from: docEditorText), in: documentID)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(text: item.text)
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
        .safeAreaInset(edge: .bottom) { bottomBar(for: document) }
        .overlay(alignment: .top) {
            if isTransformingDoc {
                BusyBanner(message: "Transforming document…").padding(.top, 8)
            }
        }
        .confirmationDialog("Transform document with…", isPresented: $showingDocTransform,
                            titleVisibility: .visible) {
            ForEach(model.documents.presets) { preset in
                Button(preset.name) { runDocumentTransform(preset, on: document) }
            }
            Button("Add New Transform…") {
                creatingTransform = PromptPreset(name: "", template: PromptPreset.transcriptToken)
            }
        }
        .sheet(item: $creatingTransform) { preset in
            PresetEditorView(preset: preset, isNew: true, saveTitle: "Save & Run") { saved in
                runDocumentTransform(saved, on: document)
            }
        }
        .confirmationDialog("Transform paragraph with…",
                            isPresented: Binding(get: { paragraphTransformTarget != nil },
                                                 set: { if !$0 { paragraphTransformTarget = nil } }),
                            titleVisibility: .visible) {
            ForEach(model.documents.presets) { preset in
                Button(preset.name) {
                    if let pid = paragraphTransformTarget { runParagraphTransform(preset, paragraphID: pid) }
                }
            }
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
                        Button("Replace") { recorderTask = .replace(paragraphID: para.id) }.tint(.orange)
                    }
                    // Swipe right → Transform / Edit
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button("Transform") { paragraphTransformTarget = para.id }.tint(.purple)
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
        if !document.recordings.isEmpty {
            Section("Recordings") {
                ForEach(document.recordings) { recording in
                    RecordingRow(
                        recording: recording,
                        isActive: playback.playingID == recording.id,
                        isPaused: playback.isPaused,
                        onPlay: { playback.toggle(recording, url: model.documents.audioURL(for: recording)) }
                    )
                    .onLongPressGesture { withAnimation { editMode = .active } }
                    // Swipe left → Delete
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            model.documents.deleteRecording(recording.id, fromDocument: documentID)
                        }
                    }
                    // Swipe right → Re-record / Move
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button("Re-record") { recorderTask = .rerecord(recordingID: recording.id) }.tint(.orange)
                        if !otherDocuments.isEmpty {
                            Button("Move") { movingRecording = recording }.tint(.blue)
                        }
                    }
                }
                .onMove { offsets, destination in
                    model.documents.moveRecordings(in: documentID, from: offsets, to: destination)
                }
            }

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

    // MARK: Bottom bar

    @ViewBuilder
    private func bottomBar(for document: Document) -> some View {
        if !editMode.isEditing {
            Button {
                showingDocTransform = true
            } label: {
                Label("Transform", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.modelReady || isTransformingDoc || document.combinedText.isEmpty)
            .padding()
            .background(.bar)
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
        case .replace(let paragraphID):
            model.captureReplacingParagraph(audioURL: url, duration: duration,
                                            paragraphID: paragraphID, in: documentID)
        case .rerecord(let recordingID):
            model.rerecordRecording(recordingID, in: documentID, audioURL: url, duration: duration)
        }
    }

    // MARK: Paragraph editing

    private func startEditing(_ para: Document.Paragraph) {
        editingText = para.text
        editingParagraph = para
    }

    /// What a presented `RecordingSheet` should do with the finished clip.
    enum RecorderTask: Identifiable, Equatable {
        case addToRecordings
        case insertBody(at: Int)
        case replace(paragraphID: UUID)
        case rerecord(recordingID: UUID)

        var id: String {
            switch self {
            case .addToRecordings:        return "add"
            case .insertBody(let i):      return "insert-\(i)"
            case .replace(let pid):       return "replace-\(pid)"
            case .rerecord(let rid):      return "rerecord-\(rid)"
            }
        }

        var sheetTitle: String {
            switch self {
            case .addToRecordings: return "New Recording"
            case .insertBody:      return "Insert Recording"
            case .replace:         return "Replace Paragraph"
            case .rerecord:        return "Re-record"
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
/// document from the list.
struct TextEditorSheet: View {
    let title: String
    @Binding var text: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
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

// MARK: - Share

/// Wraps a piece of text so it can drive a `.sheet(item:)` share presentation.
struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

#if canImport(UIKit)
/// Bridges `UIActivityViewController` for share sheets.
struct ActivityView: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
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
    @StateObject private var recorder = AudioRecorder()
    @State private var startedURL: URL?
    @State private var didComplete = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
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
                    recorder.isPaused ? recorder.resume() : recorder.pause()
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
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(210)])
        .interactiveDismissDisabled(true)
        .task { await begin() }
        .onDisappear { discardIfUnfinished() }
        .alert("Couldn't record", isPresented: Binding(get: { errorMessage != nil },
                                                       set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { dismiss() }
        } message: { Text(errorMessage ?? "") }
    }

    /// Discard the in-progress clip and close.
    private func cancel() {
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        guard let result = recorder.stop() else { dismiss(); return }
        didComplete = true
        onComplete(result.url, result.duration)
        dismiss()
    }

    /// Swiped away without stopping: drop the in-progress clip.
    private func discardIfUnfinished() {
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
    @State private var showingBatchMove = false

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
                HStack(spacing: 24) {
                    batchButton("Delete", "trash", role: .destructive) {
                        model.documents.deleteRecordings(selected, fromDocument: documentID)
                        exitSelection()
                    }
                    batchButton("Copy", "doc.on.doc") { copySelected() }
                    batchButton("Move", "folder") { if !documentTargets.isEmpty { showingBatchMove = true } }
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
            TranscriptDetailView(recording: recording)
        }
        .confirmationDialog("Move \(selected.count) to…", isPresented: $showingBatchMove,
                            titleVisibility: .visible) {
            ForEach(documentTargets) { target in
                Button(target.title) {
                    model.documents.moveRecordings(selected, from: documentID, to: target.id)
                    exitSelection()
                }
            }
        }
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

/// Full-transcript reader for a single recording, shown when a preview row is tapped.
private struct TranscriptDetailView: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(recording.transcript?.isEmpty == false ? recording.transcript! : "(no speech detected)")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
