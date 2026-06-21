import SwiftUI
import AVFoundation
import WoodsWhisperKit

struct RecordingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var createdDocument: Document?

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Name", value: recording.name)
                LabeledContent("Created", value: recording.createdAt.formatted())
                LabeledContent("Duration", value: durationString)
                LabeledContent("Source", value: recording.origin.rawValue.capitalized)
            }

            Section {
                Button(isPlaying ? "Pause" : "Play",
                       systemImage: isPlaying ? "pause.fill" : "play.fill") { togglePlayback() }
            }

            Section {
                Button("Transcribe to Document", systemImage: "doc.text.magnifyingglass") {
                    Task {
                        createdDocument = await model.transcribeToDocument(recording)
                    }
                }
                .disabled(!model.transcriptionReady)
                if !model.transcriptionReady {
                    Text("Finish model setup in Settings to enable transcription.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let doc = createdDocument {
                Section("Created") {
                    NavigationLink(doc.title, value: doc)
                }
            }
        }
        .navigationTitle(recording.name)
        .navigationDestination(for: Document.self) { DocumentDetailView(documentID: $0.id) }
        .onDisappear { player?.stop() }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause(); isPlaying = false; return
        }
        let url = model.recordings.audioURL(for: recording)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            player = p
            isPlaying = true
        } catch {
            model.setupError = "Couldn't play audio: \(error.localizedDescription)"
        }
    }

    private var durationString: String {
        String(format: "%d:%02d", Int(recording.duration) / 60, Int(recording.duration) % 60)
    }
}
