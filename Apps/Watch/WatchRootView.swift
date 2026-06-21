import SwiftUI
import WoodsWhisperKit

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @StateObject private var recorder = AudioRecorder()

    var body: some View {
        NavigationStack {
            TabView {
                recordTab
                recordingsTab
            }
            .tabViewStyle(.verticalPage)
            .navigationTitle("Woods Whisper")
        }
    }

    private var recordTab: some View {
        VStack(spacing: 10) {
            if recorder.isRecording {
                Text(timeString(recorder.elapsed)).font(.title2.monospacedDigit())
                LevelMeter(level: recorder.currentLevel)
            } else {
                Text("Tap to record").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await toggle() }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(recorder.isRecording ? .red : .accentColor)
            }
            .buttonStyle(.plain)
            if let status = model.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding()
    }

    private var recordingsTab: some View {
        List {
            ForEach(model.recordings.recordings) { recording in
                NavigationLink {
                    WatchRecordingDetailView(recording: recording)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recording.name).font(.caption)
                            Text(recording.createdAt, style: .time)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.pendingSends.contains(recording.id) {
                            ProgressView()
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { model.recordings.delete(recording) }
                }
            }
        }
        .overlay {
            if model.recordings.recordings.isEmpty {
                Text("No recordings").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func toggle() async {
        if recorder.isRecording {
            guard let result = recorder.stop() else { return }
            model.store(audioURL: result.url, duration: result.duration)
        } else {
            guard await recorder.requestPermission() else {
                model.statusMessage = "Microphone permission needed."
                return
            }
            let new = model.recordings.newAudioURL()
            try? recorder.start(to: new.url)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
