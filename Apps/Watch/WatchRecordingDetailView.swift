import SwiftUI
import WoodsWhisperKit

/// Per-recording actions on the Watch: rename, re-send to the paired device, delete.
struct WatchRecordingDetailView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    let recording: Recording

    @State private var isRenaming = false
    @State private var newName = ""

    /// The current stored recording (the captured value goes stale after a rename).
    private var live: Recording {
        model.recordings.recording(with: recording.id) ?? recording
    }

    var body: some View {
        List {
            Section {
                Text(live.name).font(.headline)
                Text(live.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                Text(Recording.durationLabel(live.duration))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Send Again", systemImage: "paperplane") {
                    Task { await model.send(recording) }
                }
                Button("Rename", systemImage: "pencil") {
                    newName = live.name; isRenaming = true
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.recordings.delete(recording); dismiss()
                }
            }
        }
        .navigationTitle("Recording")
        .sheet(isPresented: $isRenaming) {
            VStack {
                TextField("Name", text: $newName)
                Button("Save") {
                    model.recordings.rename(recording, to: newName)
                    isRenaming = false
                }
            }
            .padding()
        }
    }
}
