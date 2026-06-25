import SwiftUI
import WoodsWhisperKit

/// A modal recording surface: a big record/stop button with the shared elapsed-time + gain meter +
/// pause/continue control while recording. On stop it hands the finished file back via `onComplete`;
/// cancelling discards the clip. Used for "New Recording" (→ Inbox) and the in-document insert /
/// replace flows.
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
