import SwiftUI
import WoodsWhisperKit

struct RecordingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var recorder = AudioRecorder()
    @State private var renameTarget: Recording?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recordBar
                Divider()
                list
            }
            .navigationTitle("Recordings")
        }
    }

    private var recordBar: some View {
        VStack(spacing: 8) {
            if recorder.isRecording {
                LevelMeter(level: recorder.currentLevel)
                Text(timeString(recorder.elapsed)).monospacedDigit().font(.title3)
            }
            Button {
                Task { await toggleRecording() }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(recorder.isRecording ? .red : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    private var list: some View {
        List {
            ForEach(model.recordings.recordings) { recording in
                NavigationLink(value: recording) {
                    RecordingRow(recording: recording)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { model.recordings.delete(recording) }
                    Button("Rename") { startRename(recording) }.tint(.blue)
                }
            }
            .onDelete { model.recordings.delete(at: $0) }
        }
        .navigationDestination(for: Recording.self) { RecordingDetailView(recording: $0) }
        .overlay {
            if model.recordings.recordings.isEmpty {
                ContentUnavailableView("No recordings yet",
                                       systemImage: "waveform",
                                       description: Text("Tap record, or capture one on your Watch."))
            }
        }
        .alert("Rename recording", isPresented: Binding(get: { renameTarget != nil },
                                                        set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let target = renameTarget { model.recordings.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            guard let result = recorder.stop() else { return }
            let id = UUID()
            let fileName = result.url.lastPathComponent
            let recording = Recording(id: id, duration: result.duration,
                                      audioFileName: fileName, origin: deviceOrigin())
            model.recordings.add(recording)
        } else {
            guard await recorder.requestPermission() else {
                model.setupError = "Microphone permission is required to record."
                return
            }
            let new = model.recordings.newAudioURL()
            try? recorder.start(to: new.url)
        }
    }

    private func deviceOrigin() -> Recording.Origin {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #else
        return .phone
        #endif
    }

    private func startRename(_ recording: Recording) {
        renameText = recording.name
        renameTarget = recording
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct RecordingRow: View {
    let recording: Recording
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(recording.name)
                Text(recording.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(durationString).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var icon: String {
        switch recording.origin {
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .pad: return "ipad"
        }
    }
    private var durationString: String {
        String(format: "%d:%02d", Int(recording.duration) / 60, Int(recording.duration) % 60)
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.red).frame(width: geo.size.width * CGFloat(level))
            }
        }
        .frame(height: 6)
        .padding(.horizontal)
    }
}
