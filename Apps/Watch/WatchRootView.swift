import SwiftUI
import WoodsWhisperKit

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @StateObject private var recorder = AudioRecorder()
    @State private var tab: Tab = .record

    /// Screen order top-to-bottom: Pairing, Record, List. Record is the default, so you swipe up
    /// to the list and down to pairing.
    private enum Tab { case pairing, record, list }

    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                settingsTab.tag(Tab.pairing)
                recordTab.tag(Tab.record)
                recordingsTab.tag(Tab.list)
            }
            .tabViewStyle(.verticalPage)
        }
    }

    private var recordTab: some View {
        VStack(spacing: 10) {
            if recorder.isRecording {
                Text(timeString(recorder.elapsed))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(recorder.isPaused ? .secondary : .primary)
                HStack(spacing: 8) {
                    LevelMeter(level: recorder.currentLevel)
                    Button {
                        recorder.isPaused ? recorder.resume() : recorder.pause()
                    } label: {
                        Image(systemName: recorder.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.title3)
                            .foregroundStyle(recorder.isPaused ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            Text(recording.name).font(.caption)
                            Spacer()
                            sendStatusIcon(for: recording.id)
                        }
                        if let fraction = model.sendProgress[recording.id] {
                            ProgressView(value: fraction)   // full-width bar beneath the item
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await model.send(recording) }
                    } label: {
                        Label(model.sendOutcome[recording.id] == .failed ? "Retry" : "Send",
                              systemImage: "paperplane")
                    }
                    .tint(.blue)
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

    /// Trailing send status for a row: spinner while in flight (no byte progress), ✓ when sent,
    /// ⚠︎ when the last attempt failed. When a determinate bar is showing it renders below instead.
    @ViewBuilder
    private func sendStatusIcon(for id: UUID) -> some View {
        if model.sendProgress[id] != nil {
            EmptyView()
        } else if model.pendingSends.contains(id) {
            ProgressView()
        } else {
            switch model.sendOutcome[id] {
            case .sent:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case nil:
                EmptyView()
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
