import SwiftUI
import AVFoundation
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

/// A document: its constituent recordings (each with its own transcript) plus model
/// transformations over the combined transcript.
///
/// • "Add Recording" (top) records straight into this document — no Inbox detour.
/// • Long-press a recording to enter selection mode for batch delete / copy / move.
struct DocumentDetailView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    @StateObject private var recorder = AudioRecorder()

    // Transform
    @State private var showingPresetPicker = false
    @State private var isRunning = false
    @State private var runningPresetName = ""
    @State private var streamingOutput = ""

    // Single-recording rename
    @State private var renameTarget: Recording?
    @State private var renameText = ""

    // Playback
    @State private var player: AVAudioPlayer?
    @State private var playingID: UUID?

    // Selection mode
    @State private var selectionMode = false
    @State private var selected: Set<UUID> = []
    @State private var showingBatchMove = false

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
        .onDisappear { stopPlayback() }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for document: Document) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(document.recordings) { recording in
                    RecordingCard(
                        recording: recording,
                        selectionMode: selectionMode,
                        isSelected: selected.contains(recording.id),
                        isPlaying: playingID == recording.id,
                        onTap: { if selectionMode { toggle(recording.id) } },
                        onLongPress: { enterSelection(with: recording.id) },
                        onPlay: { togglePlayback(recording) },
                        onRetranscribe: { Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) } },
                        onCopy: { copyTranscript(recording) },
                        onRename: { startRename(recording) },
                        onDelete: { model.documents.deleteRecording(recording.id, fromDocument: documentID) },
                        moveTargets: otherDocuments,
                        onMove: { target in model.documents.moveRecording(recording.id, from: documentID, to: target.id) }
                    )
                }

                if document.recordings.isEmpty {
                    Text("No recordings yet. Tap “Add Recording” to start.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }

                if !document.transformations.isEmpty || isRunning {
                    transformationsSection(for: document)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { bottomBar(for: document) }
        .alert("Rename recording", isPresented: Binding(get: { renameTarget != nil },
                                                        set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let t = renameTarget {
                    model.documents.renameRecording(t.id, inDocument: documentID, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Transform with…", isPresented: $showingPresetPicker, titleVisibility: .visible) {
            ForEach(model.documents.presets) { preset in
                Button(preset.name) { run(preset, on: document) }
            }
        }
        .confirmationDialog("Move \(selected.count) to…", isPresented: $showingBatchMove, titleVisibility: .visible) {
            ForEach(otherDocuments) { target in
                Button(target.title) {
                    model.documents.moveRecordings(selected, from: documentID, to: target.id)
                    exitSelection()
                }
            }
        }
    }

    private var otherDocuments: [Document] {
        model.documents.documents.filter { $0.id != documentID }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(for document: Document?) -> some ToolbarContent {
        if selectionMode {
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
                Button {
                    Task { await toggleRecording(in: document) }
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Add Recording",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                }
                .tint(recorder.isRecording ? .red : .accentColor)
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
                batchButton("Move", "folder") {
                    if !otherDocuments.isEmpty { showingBatchMove = true }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.bar)
        } else if recorder.isRecording {
            HStack(spacing: 16) {
                Text(timeString(recorder.elapsed)).monospacedDigit().font(.headline)
                LevelMeter(level: recorder.currentLevel)
            }
            .padding()
            .background(.bar)
        } else {
            Button {
                showingPresetPicker = true
            } label: {
                Label("Transform", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.modelReady || isRunning || document.combinedTranscript.isEmpty)
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

    // MARK: Transformations

    @ViewBuilder
    private func transformationsSection(for document: Document) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transformations").font(.headline)
            ForEach(document.transformations) { t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.presetName).font(.subheadline.weight(.semibold))
                    Text(t.output).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            if isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Running \(runningPresetName)…", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(streamingOutput.isEmpty ? "…" : streamingOutput).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: Selection helpers

    private func enterSelection(with id: UUID) {
        guard !selectionMode else { return }
        stopPlayback()
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

    // MARK: Actions

    private func run(_ preset: PromptPreset, on document: Document) {
        runningPresetName = preset.name
        streamingOutput = ""
        isRunning = true
        Task {
            await model.runTransformation(preset, on: document) { chunk in
                Task { @MainActor in streamingOutput += chunk }
            }
            isRunning = false
        }
    }

    private func toggleRecording(in document: Document?) async {
        guard let document else { return }
        if recorder.isRecording {
            guard let result = recorder.stop() else { return }
            model.addDeviceRecording(audioURL: result.url,
                                     duration: result.duration,
                                     toDocument: document.id)
        } else {
            guard await recorder.requestPermission() else {
                model.setupError = "Microphone permission is required to record."
                return
            }
            let new = model.documents.newAudioURL()
            try? recorder.start(to: new.url)
        }
    }

    private func copyTranscript(_ recording: Recording) {
        #if canImport(UIKit)
        UIPasteboard.general.string = recording.transcript
        #endif
        wwLog("Copied transcript of “\(recording.name)”", .general)
    }

    private func startRename(_ recording: Recording) {
        renameText = recording.name
        renameTarget = recording
    }

    private func togglePlayback(_ recording: Recording) {
        if playingID == recording.id { stopPlayback(); return }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: model.documents.audioURL(for: recording))
            p.play()
            player = p
            playingID = recording.id
        } catch {
            model.setupError = "Couldn't play audio: \(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Recording card

private struct RecordingCard: View {
    let recording: Recording
    let selectionMode: Bool
    let isSelected: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onPlay: () -> Void
    let onRetranscribe: () -> Void
    let onCopy: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let moveTargets: [Document]
    let onMove: (Document) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                transcriptView          // transcript (or status) first…
                metadata                 // …with small metadata below it
                if !selectionMode {
                    Divider()
                    actionRow
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap() }
        .onLongPressGesture { onLongPress() }
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
            }
            if recording.status == .failed {
                Button(action: onRetranscribe) { Image(systemName: "arrow.clockwise") }
            }
            Spacer()
            Menu {
                Button("Retranscribe", systemImage: "arrow.clockwise", action: onRetranscribe)
                if recording.transcript?.isEmpty == false {
                    Button("Copy Transcript", systemImage: "doc.on.doc", action: onCopy)
                }
                Button("Rename", systemImage: "pencil", action: onRename)
                if !moveTargets.isEmpty {
                    Menu("Move to…") {
                        ForEach(moveTargets) { target in
                            Button(target.title) { onMove(target) }
                        }
                    }
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
            // No textSelection here: its long-press would fight the card's long-press-to-select.
            // Use selection mode → Copy (or the ⋯ menu) to copy transcripts.
            Text(recording.transcript?.isEmpty == false ? recording.transcript! : "(no speech detected)")
        case .transcribing:
            HStack(spacing: 8) { ProgressView(); Text("Transcribing…").foregroundStyle(.secondary) }
        case .pending:
            Label("Waiting to transcribe", systemImage: "clock").foregroundStyle(.secondary)
        case .failed:
            Label("Transcription failed — tap retry", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var metadata: some View {
        Text(metadataString)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var metadataString: String {
        // The default name spans two lines (date/time + length - size); flatten it so this
        // caption stays on one line. Renamed recordings show their custom name instead.
        let name = recording.name.replacingOccurrences(of: "\n", with: " · ")
        return "\(name) · \(recording.origin.rawValue)"
    }
}
