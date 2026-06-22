import SwiftUI
import AVFoundation
import WoodsWhisperKit

/// A document: its constituent recordings (each with its own transcript) plus model
/// transformations over the combined transcript. Record into the document to add a clip.
struct DocumentDetailView: View {
    @EnvironmentObject private var model: AppModel
    let documentID: UUID

    @StateObject private var recorder = AudioRecorder()
    @State private var showingPresetPicker = false
    @State private var isRunning = false
    @State private var runningPresetName = ""
    @State private var streamingOutput = ""

    @State private var renameTarget: Recording?
    @State private var renameText = ""

    @State private var player: AVAudioPlayer?
    @State private var playingID: UUID?

    private var document: Document? { model.documents.document(with: documentID) }

    var body: some View {
        Group {
            if let document {
                content(for: document)
            } else {
                ContentUnavailableView("Document not found", systemImage: "doc")
            }
        }
        .navigationTitle(document?.title ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stopPlayback() }
    }

    @ViewBuilder
    private func content(for document: Document) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(document.recordings) { recording in
                    RecordingCard(
                        recording: recording,
                        isPlaying: playingID == recording.id,
                        onPlay: { togglePlayback(recording) },
                        onRetry: { Task { await model.transcribe(recordingID: recording.id, inDocument: documentID) } },
                        onRename: { startRename(recording) },
                        onDelete: { model.documents.deleteRecording(recording.id, fromDocument: documentID) },
                        moveTargets: model.documents.documents.filter { $0.id != documentID },
                        onMove: { target in
                            model.documents.moveRecording(recording.id, from: documentID, to: target.id)
                        }
                    )
                }

                if document.recordings.isEmpty {
                    Text("No recordings yet. Tap record below to add one.")
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

    // MARK: Bottom bar (record + transform)

    private func bottomBar(for document: Document) -> some View {
        HStack(spacing: 16) {
            Button {
                Task { await toggleRecording(in: document) }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(recorder.isRecording ? .red : .accentColor)
            }
            .buttonStyle(.plain)

            if recorder.isRecording {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeString(recorder.elapsed)).monospacedDigit().font(.headline)
                    LevelMeter(level: recorder.currentLevel)
                }
            } else {
                Button {
                    showingPresetPicker = true
                } label: {
                    Label("Transform", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.modelReady || isRunning || document.combinedTranscript.isEmpty)
            }
        }
        .padding()
        .background(.bar)
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

    private func toggleRecording(in document: Document) async {
        if recorder.isRecording {
            guard let result = recorder.stop() else { return }
            model.addDeviceRecording(fileName: result.url.lastPathComponent,
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
    let isPlaying: Bool
    let onPlay: () -> Void
    let onRetry: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let moveTargets: [Document]
    let onMove: (Document) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Transcript (or status) first — the metadata sits small below it.
            transcriptView

            metadata

            Divider()

            HStack(spacing: 18) {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                }
                if recording.status == .failed {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                }
                Spacer()
                Menu {
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
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var transcriptView: some View {
        switch recording.status {
        case .done:
            Text(recording.transcript?.isEmpty == false ? recording.transcript! : "(no speech detected)")
                .textSelection(.enabled)
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
        let date = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        let dur = String(format: "%d:%02d", Int(recording.duration) / 60, Int(recording.duration) % 60)
        return "\(recording.name) · \(date) · \(dur) · \(recording.origin.rawValue)"
    }
}
