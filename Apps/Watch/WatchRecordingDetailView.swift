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

    private var isSending: Bool { model.pendingSends.contains(recording.id) }
    private var isFailed: Bool { model.sendOutcome[recording.id] == .failed }

    @ViewBuilder
    private var sendStatus: some View {
        if isSending {
            VStack(alignment: .leading, spacing: 4) {
                Label("Sending…", systemImage: "paperplane")
                    .font(.caption).foregroundStyle(.secondary)
                if let fraction = model.sendProgress[recording.id] {
                    ProgressView(value: fraction)
                }
            }
        } else {
            switch model.sendOutcome[recording.id] {
            case .sent:
                Label("Sent", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed:
                Label("Send failed — tap Retry", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        }
    }

    var body: some View {
        List {
            Section {
                Text(live.name).font(.headline)
                Text(live.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                Text(Recording.durationLabel(live.duration))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isSending || model.sendOutcome[recording.id] != nil {
                Section { sendStatus }
            }
            Section {
                Button(isFailed ? "Retry" : "Send Again", systemImage: "paperplane") {
                    Task { await model.send(recording) }
                }
                .disabled(isSending)
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
