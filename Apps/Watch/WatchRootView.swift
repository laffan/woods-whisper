import SwiftUI
import Foundation
import AppIntents
import WoodsWhisperKit

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @StateObject private var recorder = AudioRecorder()
    @State private var tab: Tab = .record
    @AppStorage("walkingMode") private var walkingMode = false
    @ObservedObject private var launcher = RecordingLauncher.shared

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
        // Launched by the "New Recording" complication / Shortcut: jump to the record screen and
        // start capturing.
        .onChange(of: launcher.pending) { _, pending in
            if pending { Task { await startFromIntent() } }
        }
        .task {
            if launcher.pending { await startFromIntent() }
        }
        .onOpenURL { url in
            if url == woodsWhisperRecordURL { launcher.request() }
        }
    }

    /// Begin a recording in response to an external request (complication / Shortcut / Siri).
    private func startFromIntent() async {
        launcher.pending = false
        tab = .record
        guard !recorder.isRecording else { return }
        guard await recorder.requestPermission() else {
            model.statusMessage = "Microphone permission needed."
            return
        }
        let new = model.recordings.newAudioURL()
        try? recorder.start(to: new.url)
    }

    private var recordTab: some View {
        VStack(spacing: 10) {
            if recorder.isRecording {
                Text(timeString(recorder.elapsed))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(recorder.isPaused ? .secondary : .primary)
                LevelMeter(level: recorder.currentLevel)
                // Cancel, stop, and pause/continue side by side, same size (matches the iPhone
                // recorder's Cancel / Stop / Pause row).
                HStack(spacing: 16) {
                    Button {
                        cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                    Button {
                        Task { await toggle() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                    Button {
                        recorder.isPaused ? recorder.resume() : recorder.pause()
                    } label: {
                        Image(systemName: recorder.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(recorder.isPaused ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(recorder.isPaused ? "Continue" : "Pause")
                }
            } else {
                // Walking toggle (replaces the old "Tap to record" label): when on, clips queue
                // locally and the record button turns green.
                Toggle(isOn: $walkingMode) {
                    Label("Walking", systemImage: "figure.walk")
                }
                .toggleStyle(.button)
                .tint(.green)
                .controlSize(.small)
                Button {
                    Task { await toggle() }
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: 56))
                        .foregroundStyle(walkingMode ? Color.green : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            if !model.pendingSends.isEmpty {
                VStack(spacing: 4) {
                    Text(sendingLabel).font(.caption2).foregroundStyle(.secondary)
                    if let fraction = model.sendProgress.values.max() {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Button(role: .destructive) {
                        model.cancelAllSends()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal)
            } else if let status = model.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }

            // Walking mode: clips queue locally; offer a one-tap batch send.
            if walkingMode, model.pendingSends.isEmpty, !model.unsentRecordings.isEmpty {
                Button {
                    model.sendAllUnsent()
                } label: {
                    Label("Send All (\(model.unsentRecordings.count))", systemImage: "paperplane.fill")
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
    }

    private var recordingsTab: some View {
        List {
            // Clips whose last send failed or was cancelled — surfaced at the top with a Resend
            // button (switch targets in Pairing first if needed).
            if !needsResend.isEmpty {
                Section {
                    ForEach(needsResend) { recordingRow($0) }
                    Button {
                        model.resendFailed()
                    } label: {
                        Label("Resend", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .tint(.blue)
                } header: {
                    Text("Needs Resend")
                }
            }

            Section {
                ForEach(others) { recordingRow($0) }
            }
        }
        .overlay {
            if model.recordings.recordings.isEmpty {
                Text("No recordings").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func recordingRow(_ recording: Recording) -> some View {
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
            if model.pendingSends.contains(recording.id) {
                Button { model.cancelSend(recording) } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .tint(.orange)
            } else {
                Button { model.startSend(recording) } label: {
                    Label(isFailedOrCancelled(recording.id) ? "Retry" : "Send", systemImage: "paperplane")
                }
                .tint(.blue)
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { model.recordings.delete(recording) }
        }
    }

    private var needsResend: [Recording] {
        model.recordings.recordings.filter { isFailedOrCancelled($0.id) }
    }

    private var others: [Recording] {
        model.recordings.recordings.filter { !isFailedOrCancelled($0.id) }
    }

    private func isFailedOrCancelled(_ id: UUID) -> Bool {
        let outcome = model.sendOutcome[id]
        return outcome == .failed || outcome == .cancelled
    }

    /// Trailing send status for a row: spinner while in flight (no byte progress), ✓ when sent,
    /// ⚠︎ when failed, ⊘ when cancelled. When a determinate bar is showing it renders below instead.
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
            case .cancelled:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
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

    /// Short, destination-aware label shown while a clip uploads.
    private var sendingLabel: String {
        WatchSettings.shared.transport == .phoneSession ? "Sending to Phone" : "Sending Direct"
    }

    /// Stop recording and discard the in-progress clip (don't store or send it).
    private func cancel() {
        guard let result = recorder.stop() else { return }
        try? FileManager.default.removeItem(at: result.url)
        model.statusMessage = nil
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

// MARK: - "New Recording" App Shortcut (watch)

/// Exposes the (shared) `StartRecordingIntent` to Siri. `AppShortcutsProvider` must live in the
/// app target; the intent itself is defined in WoodsWhisperKit so the complication extension can
/// share it.
struct WoodsWhisperWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "New recording in \(.applicationName)",
                "Start a recording in \(.applicationName)"
            ],
            shortTitle: "New Recording",
            systemImageName: "mic.fill"
        )
    }
}
