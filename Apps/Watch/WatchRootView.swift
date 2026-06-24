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
                settingsTab
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
            if !model.pendingSends.isEmpty {
                VStack(spacing: 3) {
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                    if let fraction = model.sendProgress.values.max() {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .padding(.horizontal)
            } else if let status = model.statusMessage {
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
                        if let fraction = model.sendProgress[recording.id] {
                            ProgressView(value: fraction).frame(width: 44)
                        } else if model.pendingSends.contains(recording.id) {
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

    private var settingsTab: some View {
        VStack(spacing: 12) {
            Text(destinationLabel)
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            NavigationLink {
                WatchSettingsView()
            } label: {
                Label("Settings & Pairing", systemImage: "gear")
            }
        }
        .padding()
    }

    private var destinationLabel: String {
        let iPad = WatchSettings.shared.deviceLink?.displayName ?? "iPad"
        switch WatchSettings.shared.transport {
        case .phoneSession: return "Sending to paired iPhone"
        case .localNetwork: return "Sending to \(iPad) over WiFi"
        case .bluetooth:    return "Sending to \(iPad) over Bluetooth"
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
