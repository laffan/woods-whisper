import SwiftUI
import UniformTypeIdentifiers
import WoodsWhisperKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedModel = AppSettings.shared.model
    @State private var selectedSpeechModel = AppSettings.shared.speechModel
    @State private var localServerEnabled = AppSettings.shared.localServerEnabled
    @State private var micOptions: [AudioRecorder.InputOption] = []
    @State private var selectedMicUID: String? = AppSettings.shared.preferredMicUID
    @State private var showingAuthSheet = false
    @State private var showLiveTranscription = AppSettings.shared.showLiveTranscription
    @State private var allowRotation = AppSettings.shared.allowRotation
    @State private var showingFolderPicker = false
    @State private var deviceName = AppSettings.shared.deviceDisplayName
    @FocusState private var deviceNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                microphoneSection
                displaySection
                speechModelSection
                languageModelSection
                presetsSection
                backupSection
                connectivitySection
                aboutSection
            }
            .wwForm()
            .navigationTitle("Settings")
            .onAppear { micOptions = AudioRecorder.availableInputs() }
            .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):  model.chooseBackupFolder(url)
                case .failure(let error): model.setupError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        Section {
            Picker("Microphone", selection: $selectedMicUID) {
                Text("Automatic").tag(String?.none)
                ForEach(micOptions) { option in
                    Text(option.name).tag(String?.some(option.id))
                }
            }
            .onChange(of: selectedMicUID) { _, newValue in
                AppSettings.shared.preferredMicUID = newValue
                AudioRecorder.preferredInputUID = newValue
            }
        } header: {
            WWSectionHeader("Microphone")
        } footer: {
            WWFooter("Choose which microphone to record with — built-in, wired, or Bluetooth. "
                     + "“Automatic” lets the system pick (usually the most recently connected).")
        }
        .listRowBackground(WW.surface)
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            Toggle("Allow Rotation", isOn: $allowRotation)
                .onChange(of: allowRotation) { _, on in
                    AppSettings.shared.allowRotation = on
                    #if canImport(UIKit)
                    AppDelegate.applyOrientationLock()
                    #endif
                }
        } header: {
            WWSectionHeader("Display")
        } footer: {
            WWFooter("When on, the screen rotates to landscape. Turn it off to lock the app to portrait.")
        }
        .listRowBackground(WW.surface)
    }

    // MARK: Speech model

    private var speechModelSection: some View {
        Section {
            Picker("Model", selection: $selectedSpeechModel) {
                ForEach(SpeechModel.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .onChange(of: selectedSpeechModel) { _, newValue in
                AppSettings.shared.speechModel = newValue
                Task {
                    do { try await model.transcription.setModel(newValue) }
                    catch { model.setupError = error.localizedDescription }
                    await model.refreshReadiness()
                }
            }
            Text(selectedSpeechModel.approxDownloadNote)
                .font(.caption).foregroundStyle(WW.inkSecondary)

            ModelSetupRow(title: "Speech weights", systemImage: "waveform",
                          ready: model.transcriptionReady, progress: model.speechProgress)
            if !model.transcriptionReady {
                Button(downloadTitle(preparing: model.isPreparingSpeech,
                                     started: model.speechProgress != nil)) {
                    Task { await model.prepareSpeechModel() }
                }
                .disabled(model.isPreparingSpeech)
            }

            Toggle("Show live transcription during recording", isOn: $showLiveTranscription)
                .onChange(of: showLiveTranscription) { _, on in
                    AppSettings.shared.showLiveTranscription = on
                }
        } header: {
            WWSectionHeader("Speech Model")
        } footer: {
            WWFooter("Transcribes recordings to text on-device. Parakeet is the most accurate; the "
                     + "smaller Whisper models are lighter, faster downloads. Download once while "
                     + "online; works offline afterward. Switching model requires downloading it.\n\n"
                     + "Live transcription shows a scrolling transcript above the record controls, "
                     + "re-processing the whole clip-so-far about once a second so sentences and "
                     + "punctuation settle as you speak. It runs a second on-device pass while "
                     + "recording, so it uses more battery.")
        }
        .listRowBackground(WW.surface)
    }

    // MARK: Language model

    private var languageModelSection: some View {
        Section {
            // Split into on-device vs online sections; each row carries a status icon — moss dot =
            // downloaded on device, ochre dot = not downloaded, WiFi = streams from the cloud.
            Picker("", selection: $selectedModel) {
                Section("On-device") {
                    ForEach(LanguageModelChoice.allCases.filter { !$0.isOnline }) { m in
                        modelPickerRow(m).tag(m)
                    }
                }
                Section("Online") {
                    ForEach(LanguageModelChoice.allCases.filter(\.isOnline)) { m in
                        modelPickerRow(m).tag(m)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: selectedModel) { _, newValue in
                model.selectLanguageModel(newValue)
            }

            if selectedModel.isOnline {
                // Online (Anthropic) model: authenticate with an API key instead of downloading.
                ModelSetupRow(title: "Cloud model", systemImage: "cloud",
                              ready: model.isAuthenticated, progress: nil)
                Button(model.isAuthenticated ? "Edit Authentication" : "Authenticate") {
                    showingAuthSheet = true
                }
            } else {
                ModelSetupRow(title: "Model weights", systemImage: "brain",
                              ready: model.modelReady, progress: model.llmProgress)
                if model.isPreparingLLM {
                    Button("Cancel Download", role: .destructive) {
                        model.cancelLanguageModelDownload()
                    }
                } else if model.isLanguageModelDownloaded {
                    // Downloaded models stay on device and auto-load when selected; this frees them.
                    Button("Remove Download", role: .destructive) {
                        model.removeLanguageModelDownload()
                    }
                } else if !model.modelReady {
                    Button(downloadTitle(started: model.llmProgress != nil,
                                         size: selectedModel.approxDownloadSize)) {
                        model.startLanguageModelDownload()
                    }
                }
            }
        } header: {
            WWSectionHeader("Language Model")
        } footer: {
            WWFooter("Rewrites transcripts. The on-device models (Qwen3, Llama 3.2, Gemma 3) download "
                     + "once while online and then work offline; a downloaded model reloads "
                     + "automatically when you pick it (tap Remove Download to free its space). The "
                     + "online Claude models stream from Anthropic — pick one when you have a cell "
                     + "signal and tap Authenticate to add your API key (no download).")
        }
        .listRowBackground(WW.surface)
        .sheet(isPresented: $showingAuthSheet) {
            AnthropicAuthView(isAuthenticated: model.isAuthenticated) { key in
                model.saveAnthropicAPIKey(key)
            }
        }
    }

    /// Download button label: idle → "Download", interrupted → "Resume", in-flight → "Downloading…".
    private func downloadTitle(preparing: Bool, started: Bool) -> String {
        if preparing { return "Downloading…" }
        return started ? "Resume Download" : "Download"
    }

    /// Language-model Download label, with the on-disk size on the button: "Download (~2.4 GB)" or
    /// "Resume Download (~2.4 GB)" if a previous attempt was interrupted.
    private func downloadTitle(started: Bool, size: String) -> String {
        "\(started ? "Resume Download" : "Download") (\(size))"
    }

    /// One row in the model picker: the model's name with a status icon — a moss dot when its
    /// weights are downloaded on device, an ochre dot when not, or a WiFi glyph for online models.
    private func modelPickerRow(_ m: LanguageModelChoice) -> some View {
        Label {
            Text(m.displayName)
        } icon: {
            if m.isOnline {
                Image(systemName: "wifi")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AppSettings.shared.isModelDownloaded(m.rawValue) ? WW.moss : WW.amber)
            }
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section {
            NavigationLink {
                PresetListView()
            } label: {
                Label("Manage Presets (\(model.documents.presets.count))", systemImage: "wand.and.stars")
            }
        } header: {
            WWSectionHeader("Prompt Presets")
        }
        .listRowBackground(WW.surface)
    }

    // MARK: Local backup

    private var backupSection: some View {
        BackupFolderSection(backup: model.documents.backup,
                            onChoose: { showingFolderPicker = true },
                            onBackUpNow: { model.documents.backUpNow() },
                            onTurnOff: { model.documents.clearBackupFolder() })
    }

    // MARK: Connectivity

    private var connectivitySection: some View {
        Section {
            Toggle("Receive directly from Watch (no phone)", isOn: $localServerEnabled)
                .onChange(of: localServerEnabled) { _, on in
                    AppSettings.shared.localServerEnabled = on
                    if on { model.startLocalServer() } else { model.stopLocalServer() }
                }
            if localServerEnabled {
                NavigationLink {
                    PairingView()
                } label: {
                    Label("Pair Watch", systemImage: "applewatch.radiowaves.left.and.right")
                }
            }
        } header: {
            WWSectionHeader("Connectivity")
        } footer: {
            WWFooter("On iPad, enable this to let an iPhone-free Watch send recordings — over WiFi "
                     + "when both share a network, or Bluetooth when off-grid with no WiFi. On iPhone, "
                     + "the paired Watch connects automatically.")
        }
        .listRowBackground(WW.surface)
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Device name") {
                TextField("Device name", text: $deviceName)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($deviceNameFocused)
                    .onSubmit { commitDeviceName() }
                    .onChange(of: deviceNameFocused) { _, focused in
                        if !focused { commitDeviceName() }
                    }
            }
            Text("Woods Whisper — offline voice capture, transcription, and transformation.")
                .font(.caption).foregroundStyle(WW.inkSecondary)
        } header: {
            WWSectionHeader("About")
        } footer: {
            WWFooter("The name this device advertises over WiFi and Bluetooth, and what your Watch "
                     + "shows once it's paired with it. It starts as the device's own name — clear "
                     + "the field to go back to that. A Watch that's already paired keeps the old "
                     + "name until you pair it again.")
        }
        .listRowBackground(WW.surface)
    }

    /// Save the edited device name and re-advertise under it. An empty field clears the override, so
    /// the field is re-seeded afterwards from whatever the name resolved to — the trimmed text, or
    /// the device's own name again.
    private func commitDeviceName() {
        let previous = AppSettings.shared.deviceDisplayName
        AppSettings.shared.deviceDisplayName = deviceName
        deviceName = AppSettings.shared.deviceDisplayName
        guard deviceName != previous else { return }
        model.deviceNameDidChange()
    }
}

/// The Local Backup settings section. Split out (rather than written inline like the other
/// sections) so it can observe the `LocalBackupStore` directly and refresh as syncs land.
struct BackupFolderSection: View {
    @ObservedObject var backup: LocalBackupStore
    let onChoose: () -> Void
    let onBackUpNow: () -> Void
    let onTurnOff: () -> Void

    var body: some View {
        Section {
            if let folder = backup.folderName {
                LabeledContent("Folder") {
                    Text("\(folder)/\(LocalBackupStore.rootFolderName)")
                        .foregroundStyle(WW.inkSecondary)
                }
                LabeledContent("Last saved") {
                    Text(backup.lastBackupAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
                         ?? "Not yet")
                        .foregroundStyle(WW.inkSecondary)
                }
                Button("Back Up Now", action: onBackUpNow)
                Button("Change Folder…", action: onChoose)
                Button("Turn Off Backup", role: .destructive, action: onTurnOff)
                    .foregroundStyle(WW.ember)
            } else {
                Button("Choose Backup Folder…", action: onChoose)
            }
            if let error = backup.lastError {
                Text(error).font(.caption).foregroundStyle(WW.ember)
            }
        } header: {
            WWSectionHeader("Local Backup")
        } footer: {
            WWFooter("Keeps a plain-text copy of your writing in a folder you choose — on this "
                     + "device or in Files/iCloud Drive. Woods Whisper creates a "
                     + "“\(LocalBackupStore.rootFolderName)” folder there with "
                     + "“\(MarkdownBackup.inboxFolderName)” (one Markdown file per Inbox recording, "
                     + "named by when it was captured) and “\(MarkdownBackup.documentsFolderName)” "
                     + "(one file per document, named by its title). Every edit saves a fresh copy, "
                     + "overwriting the previous one. Audio isn't backed up.")
        }
        .listRowBackground(WW.surface)
    }
}

struct StatusDot: View {
    let ready: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ready ? WW.moss : WW.amber).frame(width: 8, height: 8)
            Text(ready ? "Ready" : "Not ready").font(.caption).foregroundStyle(WW.inkSecondary)
        }
    }
}

/// Collects (or updates) the Anthropic API key for the online Claude models. The current key is
/// never shown back — the field starts empty and the user pastes a fresh key to set or replace it,
/// or taps Remove Key to clear it. The key is stored in the Keychain by `AppModel.saveAnthropicAPIKey`.
struct AnthropicAuthView: View {
    let isAuthenticated: Bool
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    WWSectionHeader("Anthropic API Key")
                } footer: {
                    WWFooter("Used to stream Claude Sonnet / Haiku for the online Language Model. Create "
                             + "a key at console.anthropic.com → API Keys. It's stored in your device "
                             + "Keychain and sent only to Anthropic.")
                }
                .listRowBackground(WW.surface)

                if isAuthenticated {
                    Section {
                        Button("Remove Key", role: .destructive) {
                            onSave("")
                            dismiss()
                        }
                        .foregroundStyle(WW.ember)
                    } footer: {
                        WWFooter("A key is already saved. Enter a new one above to replace it, or remove it.")
                    }
                    .listRowBackground(WW.surface)
                }
            }
            .wwForm()
            .navigationTitle(isAuthenticated ? "Edit Authentication" : "Authenticate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(apiKey)
                        dismiss()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// A model row that shows a status dot normally, or a determinate download bar while preparing —
/// with "downloaded MB / total MB" beneath it when the downloader reports byte counts.
struct ModelSetupRow: View {
    let title: String
    let systemImage: String
    let ready: Bool
    let progress: DownloadProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let progress {
                    Text("\(Int(progress.fractionCompleted * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WW.inkSecondary)
                } else {
                    StatusDot(ready: ready)
                }
            }
            if let progress {
                ProgressView(value: progress.fractionCompleted)
                    .tint(WW.moss)
                if let summary = progress.byteSummary ?? progress.detail {
                    Text(summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WW.inkSecondary)
                }
            }
        }
    }
}
