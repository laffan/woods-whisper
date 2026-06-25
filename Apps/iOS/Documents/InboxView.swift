import SwiftUI
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

/// The Inbox: a flat list of recordings (Watch clips and "New Recording" captures), not a
/// document. Each recording can be played, copied, moved into a document, re-transcribed, or
/// deleted.
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
