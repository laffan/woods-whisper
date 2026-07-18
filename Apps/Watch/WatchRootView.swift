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
    @State private var showingDeleteAll = false
    @State private var showingCancelConfirm = false

    /// Horizontal paging within the Record tab: 0 = the recorder, 1 = the document-target picker
    /// (swipe left from the recorder to reach it).
    @State private var recordPage = 0

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
        // Launched by the "New Recording" Shortcut / Siri (App Intent): the intent sets
        // `launcher.pending`; jump to the record screen and start capturing.
        .onChange(of: launcher.pending) { _, pending in
            if pending { Task { await startFromIntent() } }
        }
        .task {
            if launcher.pending { await startFromIntent() }
        }
        // Launched by the "New Recording" complication via its `woodswhisper://record` deep link.
        // Start capturing directly rather than bouncing through the launcher, so a cold launch from
        // the complication reliably begins recording.
        .onOpenURL { url in
            guard url.scheme == woodsWhisperRecordURL.scheme else { return }
            Task { await startFromIntent() }
        }
    }

    /// Begin a recording in response to an external request (complication / Shortcut / Siri).
    private func startFromIntent() async {
        launcher.pending = false
        tab = .record
        recordPage = 0
        guard !recorder.isRecording else { return }
        guard await recorder.requestPermission() else {
            model.statusMessage = "Microphone permission needed."
            return
        }
        let new = model.recordings.newAudioURL()
        do {
            try recorder.start(to: new.url)
        } catch {
            model.statusMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    /// The Record tab pages horizontally: the recorder itself, and — one swipe left — a picker for
    /// the document new recordings are filed into.
    private var recordTab: some View {
        TabView(selection: $recordPage) {
            recordScreen.tag(0)
            documentPickerScreen.tag(1)
        }
        .tabViewStyle(.page)
    }

    private var recordScreen: some View {
        VStack(spacing: 10) {
            if recorder.isRecording {
                Text(timeString(recorder.elapsed))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(recorder.isPaused ? .secondary : .primary)
                LevelMeter(level: recorder.currentLevel)
                // Cancel / Stop / Pause as equal-width rectangular buttons that scale to fit the
                // watch width (matches the iPhone recorder's Cancel / Stop / Pause row) — circular
                // glyphs were getting clipped at the screen edge.
                HStack(spacing: 6) {
                    Button {
                        showingCancelConfirm = true
                    } label: {
                        Image(systemName: "xmark")
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .accessibilityLabel("Cancel")
                    Button {
                        Task { await toggle() }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("Save")
                    Button {
                        recorder.isPaused ? recorder.resume() : recorder.pause()
                    } label: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.bordered)
                    .tint(recorder.isPaused ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(recorder.isPaused ? "Continue" : "Pause")
                }
            } else {
                // Current record target — tap (or swipe left) to change where clips are filed.
                // Shows the destination device first, then the folder: e.g. "iPhone - Inbox".
                Button {
                    withAnimation { recordPage = 1 }
                } label: {
                    Label("\(targetDeviceName) - \(model.targetName)", systemImage: "tray.and.arrow.down")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                // Walking toggle (icon-only) and the record button, side by side at equal size.
                // When Walking is on, clips queue locally and the record button turns green.
                HStack(spacing: 6) {
                    Toggle(isOn: $walkingMode) {
                        Image(systemName: "figure.walk")
                            .font(.title3)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .toggleStyle(.button)
                    .tint(.green)
                    .accessibilityLabel("Walking")
                    Button {
                        Task { await toggle() }
                    } label: {
                        Image(systemName: "record.circle")
                            .font(.title3)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(walkingMode ? Color.green : Color.accentColor)
                    .accessibilityLabel("Record")
                }
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
        }
        .padding()
        .confirmationDialog("Discard this recording?", isPresented: $showingCancelConfirm,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { cancel() }
            Button("Keep Recording", role: .cancel) { }
        }
    }

    /// The device recordings are sent to, shown first on the record screen's target label. Mirrors
    /// `destinationLabel` but as a bare name suitable for the inline "Device - Folder" format.
    private var targetDeviceName: String {
        switch WatchSettings.shared.transport {
        case .phoneSession:
            return "iPhone"
        case .localNetwork, .bluetooth:
            return WatchSettings.shared.deviceLink?.displayName ?? "iPad"
        }
    }

    /// Document-target picker (swipe left from the recorder): Inbox on top, then the documents synced
    /// from the iPhone. Tapping one selects it and swipes back to the recorder.
    private var documentPickerScreen: some View {
        List {
            Section {
                targetRow(id: nil, title: "Inbox", icon: "tray.and.arrow.down")
                ForEach(model.documents) { doc in
                    targetRow(id: doc.id, title: doc.title, icon: "doc.text")
                }
            } header: {
                Text("Record to")
            } footer: {
                if model.documents.isEmpty {
                    Text("Documents from your iPhone appear here once it's paired and open.")
                }
            }

            // Manual pull, in case the automatic iPhone → Watch sync hasn't landed yet.
            Section {
                Button {
                    model.refreshDocuments()
                } label: {
                    if model.isRefreshingDocuments {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Refreshing…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Refresh Documents", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(model.isRefreshingDocuments)
            }
        }
    }

    /// One selectable target row: shows a checkmark on the current selection.
    @ViewBuilder
    private func targetRow(id: UUID?, title: String, icon: String) -> some View {
        Button {
            model.selectTarget(id)
            withAnimation { recordPage = 0 }
        } label: {
            HStack {
                Label(title, systemImage: icon).lineLimit(1)
                Spacer()
                if model.targetDocumentID == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private var recordingsTab: some View {
        List {
            // Clips captured during a walk (Walking mode) that haven't been sent yet — flush
            // everything unsent with one tap once you're back in range.
            if !model.walkingRecordings.isEmpty {
                Section {
                    ForEach(model.walkingRecordings) { recordingRow($0) }
                    Button {
                        model.sendAllUnsent()
                    } label: {
                        Label("Send Unsent", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                } header: {
                    Text("Walking")
                }
            }

            // Clips whose last send failed or was cancelled — surfaced with a Resend button
            // (switch targets in Pairing first if needed).
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

            // Clips confirmed delivered to the paired device, filed into their own "Sent" folder
            // and kept out of "Send All". Clear them to reclaim local space, or resend the batch.
            if !model.sentRecordings.isEmpty {
                Section {
                    ForEach(model.sentRecordings) { recordingRow($0) }
                    Button {
                        model.resendSent()
                    } label: {
                        Label("Resend All", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .tint(.blue)
                    Button(role: .destructive) {
                        model.clearSent()
                    } label: {
                        Label("Clear Sent", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Sent")
                }
            }

            // Batch actions at the bottom of the list: send everything not yet sent, or wipe the
            // Watch's local recordings (with confirmation). Independent of Walking mode.
            if !model.recordings.recordings.isEmpty {
                Section {
                    Button {
                        model.sendAllUnsent()
                    } label: {
                        Label("Send All", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.blue)
                    .disabled(model.unsentRecordings.isEmpty)

                    Button(role: .destructive) {
                        showingDeleteAll = true
                    } label: {
                        Label("Delete All", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .overlay {
            if model.recordings.recordings.isEmpty {
                Text("No recordings").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete all recordings?", isPresented: $showingDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { model.deleteAllRecordings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes every recording on this Watch.")
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
        model.recordings.recordings.filter {
            !isFailedOrCancelled($0.id)
                && !model.walkingClipIDs.contains($0.id)
                && model.sendOutcome[$0.id] != .sent
        }
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
        switch WatchSettings.shared.transport {
        case .phoneSession:
            return "Sending to Phone"
        case .localNetwork, .bluetooth:
            return "Sending to \(WatchSettings.shared.deviceLink?.displayName ?? "iPad")"
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
