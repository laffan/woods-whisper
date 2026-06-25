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

    // Body reorder (long-press a paragraph → drag to rearrange)
    @State private var editMode: EditMode = .inactive

    // Recording-selection mode (long-press a recording)
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []
    @State private var showingBatchMove = false

    // Transform
    @State private var showingDocTransform = false
    @State private var paragraphTransformTarget: UUID?
    @State private var isTransformingDoc = false
    @State private var transformingParagraphID: UUID?

    // Paragraph editing
    @State private var editingParagraph: Document.Paragraph?
    @State private var editingText = ""

    // Recording flows (insert / replace / add-to-recordings) routed through one sheet
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
        .navigationTitle(selectionMode ? "\(selected.count) selected" : (document?.title ?? "Document"))
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
            ParagraphEditor(text: $editingText) {
                model.documents.updateParagraph(para.id, in: documentID, to: editingText)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for document: Document) -> some View {
        List {
            bodySection(for: document)
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
        .confirmationDialog("Move \(selected.count) to…", isPresented: $showingBatchMove,
                            titleVisibility: .visible) {
            ForEach(otherDocuments) { target in
                Button(target.title) {
                    model.documents.moveRecordings(selected, from: documentID, to: target.id)
                    exitSelection()
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
                InsertHereButton { recorderTask = .insertBody(at: 0) }
            } else {
                if !editMode.isEditing {
                    InsertHereButton { recorderTask = .insertBody(at: 0) }
                }
                ForEach(document.paragraphs) { para in
                    let position = (document.paragraphs.firstIndex(of: para) ?? 0) + 1
                    VStack(alignment: .leading, spacing: 10) {
                        paragraphContent(para)
                        if !editMode.isEditing {
                            InsertHereButton { recorderTask = .insertBody(at: position) }
                        }
                    }
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        guard !selectionMode else { return }
                        withAnimation { editMode = .active }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            model.documents.deleteParagraph(para.id, in: documentID)
                        }
                        Button("Replace") { recorderTask = .replace(paragraphID: para.id) }.tint(.orange)
                        Button("Edit") { startEditing(para) }.tint(.blue)
                        Button("Transform") { paragraphTransformTarget = para.id }.tint(.purple)
                    }
                }
                .onMove { offsets, destination in
                    model.documents.moveParagraphs(in: documentID, from: offsets, to: destination)
                }
            }
        } header: {
            Text(document.title)
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

    // MARK: Recordings section

    @ViewBuilder
    private func recordingsSection(for document: Document) -> some View {
        if !document.recordings.isEmpty {
            Section("Recordings") {
                ForEach(document.recordings) { recording in
                    RecordingRow(
                        recording: recording,
                        selectionMode: selectionMode,
                        isSelected: selected.contains(recording.id),
                        isActive: playback.playingID == recording.id,
                        isPaused: playback.isPaused,
                        onTap: { if selectionMode { toggle(recording.id) } },
                        onLongPress: { enterSelection(with: recording.id) },
                        onPlay: { playback.toggle(recording, url: model.documents.audioURL(for: recording)) },
                        onRetranscribe: { Task { await model.retranscribeIntoBody(recordingID: recording.id, in: documentID) } },
                        onCopy: { copyTranscript(recording) },
                        onDelete: { model.documents.deleteRecording(recording.id, fromDocument: documentID) }
                    )
                    .moveDisabled(true)
                }
            }
        }
    }

    private var otherDocuments: [Document] {
        model.documents.documents.filter { $0.id != documentID && $0.title != DocumentStore.inboxTitle }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(for document: Document?) -> some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { withAnimation { editMode = .inactive } }
            }
        } else if selectionMode {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { exitSelection() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(selected.count == (document?.recordings.count ?? 0) ? "Deselect All" : "Select All") {
                    if let document { selectAll(in: document) }
                }
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
        if selectionMode {
            HStack(spacing: 24) {
                batchButton("Delete", "trash", role: .destructive) {
                    model.documents.deleteRecordings(selected, fromDocument: documentID)
                    exitSelection()
                }
                batchButton("Copy", "doc.on.doc") { copySelectedTranscripts(in: document) }
                batchButton("Move", "folder") { if !otherDocuments.isEmpty { showingBatchMove = true } }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.bar)
        } else if !editMode.isEditing {
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

    // MARK: Selection helpers

    private func enterSelection(with id: UUID) {
        guard !selectionMode, !editMode.isEditing else { return }
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

    private func selectAll(in document: Document) {
        let all = Set(document.recordings.map(\.id))
        selected = (selected == all) ? [] : all
    }

    private func copySelectedTranscripts(in document: Document) {
        let text = document.recordings
            .filter { selected.contains($0.id) }
            .compactMap { $0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        wwLog("Copied \(selected.count) recording transcript(s) to clipboard", .general)
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
            model.addDeviceRecording(audioURL: url, duration: duration, toDocument: documentID)
        case .insertBody(let position):
            model.addDeviceRecording(audioURL: url, duration: duration, toDocument: documentID,
                                     insertingTranscriptAt: position)
        case .replace(let paragraphID):
            model.captureReplacingParagraph(audioURL: url, duration: duration,
                                            paragraphID: paragraphID, in: documentID)
        }
    }

    // MARK: Paragraph editing

    private func startEditing(_ para: Document.Paragraph) {
        editingText = para.text
        editingParagraph = para
    }

    private func copyTranscript(_ recording: Recording) {
        #if canImport(UIKit)
        UIPasteboard.general.string = recording.transcript
        #endif
        wwLog("Copied transcript of “\(recording.name)”", .general)
    }

    /// What a presented `RecordingSheet` should do with the finished clip.
    enum RecorderTask: Identifiable {
        case addToRecordings
        case insertBody(at: Int)
        case replace(paragraphID: UUID)

        var id: String {
            switch self {
            case .addToRecordings:        return "add"
            case .insertBody(let i):      return "insert-\(i)"
            case .replace(let pid):       return "replace-\(pid)"
            }
        }

        var sheetTitle: String {
            switch self {
            case .addToRecordings: return "New Recording"
            case .insertBody:      return "Insert Recording"
            case .replace:         return "Replace Paragraph"
            }
        }
    }
}

// MARK: - Insert-here button

private struct InsertHereButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Add recording here", systemImage: "plus.circle")
                .font(.caption)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }
}

// MARK: - Paragraph editor

private struct ParagraphEditor: View {
    @Binding var text: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("Edit Paragraph")
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

// MARK: - Recording row

private struct RecordingRow: View {
    let recording: Recording
    let selectionMode: Bool
    let isSelected: Bool
    let isActive: Bool
    let isPaused: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onPlay: () -> Void
    let onRetranscribe: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                transcriptView
                metadata
                if !selectionMode {
                    actionRow
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture { onLongPress() }
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            Button(action: onPlay) {
                Image(systemName: (isActive && !isPaused) ? "pause.fill" : "play.fill")
            }
            Spacer()
            Menu {
                Button("Re-transcribe to document", systemImage: "text.append", action: onRetranscribe)
                if recording.transcript?.isEmpty == false {
                    Button("Copy Transcript", systemImage: "doc.on.doc", action: onCopy)
                }
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    @ViewBuilder
    private var transcriptView: some View {
        switch recording.status {
        case .done:
            Text(recording.transcript?.isEmpty == false ? recording.transcript! : "(no speech detected)")
        case .transcribing:
            HStack(spacing: 8) { ProgressView(); Text("Transcribing…").foregroundStyle(.secondary) }
        case .pending:
            Label("Waiting to transcribe", systemImage: "clock").foregroundStyle(.secondary)
        case .failed:
            Label("Transcription failed — Re-transcribe to retry", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var metadata: some View {
        Text(recording.name.replacingOccurrences(of: "\n", with: " · ") + " · " + recording.origin.rawValue)
            .font(.caption2)
            .foregroundStyle(.secondary)
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

/// A modal recording surface: a big record/stop button with the shared elapsed-time + gain meter +
/// pause/continue control while recording. On stop it hands the finished file back via `onComplete`;
/// cancelling discards the clip. Used for "New Recording" (→ Inbox) and the in-document insert /
/// replace flows. Lives here (not a standalone file) so the app target picks it up without an
/// xcodegen regen.
struct RecordingSheet: View {
    let title: String
    /// Supplies a fresh URL to record into (e.g. `store.newAudioURL().url`).
    let makeURL: () -> URL
    /// Called with the finished file and its duration when the user taps stop.
    let onComplete: (URL, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = AudioRecorder()
    @State private var startedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                if recorder.isRecording {
                    RecordingBar(elapsed: recorder.elapsed, level: recorder.currentLevel,
                                 isPaused: recorder.isPaused, onTogglePause: togglePause)
                        .padding(.horizontal)
                    Text(recorder.isPaused ? "Paused" : "Recording…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Tap to start recording")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Button {
                    Task { await toggle() }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 72))
                        .foregroundStyle(recorder.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
            .alert("Couldn't record", isPresented: Binding(get: { errorMessage != nil },
                                                           set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .interactiveDismissDisabled(recorder.isRecording)
    }

    private func toggle() async {
        if recorder.isRecording {
            guard let result = recorder.stop() else { dismiss(); return }
            onComplete(result.url, result.duration)
            dismiss()
        } else {
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
    }

    private func togglePause() {
        recorder.isPaused ? recorder.resume() : recorder.pause()
    }

    private func cancel() {
        if recorder.isRecording {
            _ = recorder.stop()
            if let url = startedURL { try? FileManager.default.removeItem(at: url) }
        }
        dismiss()
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
                    isActive: playback.playingID == recording.id,
                    isPaused: playback.isPaused,
                    onPlay: { playback.toggle(recording, url: model.documents.audioURL(for: recording)) },
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
        .navigationTitle(DocumentStore.inboxTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingRecorder = true } label: { Image(systemName: "mic.badge.plus") }
                    .accessibilityLabel("New Recording")
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
    let isActive: Bool
    let isPaused: Bool
    let onPlay: () -> Void
    let onCopy: () -> Void
    let onRetranscribe: () -> Void
    let moveTargets: [Document]
    let onMove: (Document) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            transcriptView
            HStack(spacing: 18) {
                Button(action: onPlay) {
                    Image(systemName: (isActive && !isPaused) ? "pause.fill" : "play.fill")
                }
                Spacer()
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
                    Image(systemName: "ellipsis.circle")
                }
            }
            .font(.title3)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            Text(metadataString).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var transcriptView: some View {
        switch recording.status {
        case .done:
            Text(recording.transcript?.isEmpty == false ? recording.transcript! : "(no speech detected)")
        case .transcribing:
            HStack(spacing: 8) { ProgressView(); Text("Transcribing…").foregroundStyle(.secondary) }
        case .pending:
            Label("Waiting to transcribe", systemImage: "clock").foregroundStyle(.secondary)
        case .failed:
            Label("Transcription failed — tap Retranscribe", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var metadataString: String {
        let name = recording.name.replacingOccurrences(of: "\n", with: " · ")
        return "\(name) · \(recording.origin.rawValue)"
    }
}
