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
    /// Bound straight to the stored value the app root hands down as an environment value, so the
    /// slider moves and every screen showing transcription text redraws at the new size.
    @AppStorage(AppSettings.transcriptTextSizeKey)
    private var transcriptTextSize = AppSettings.defaultTranscriptTextSize
    @State private var showingFolderPicker = false
    @State private var deviceName = AppSettings.shared.deviceDisplayName
    @State private var graphAutoTransformID: UUID? = AppSettings.shared.graphAutoTransformPresetID
    /// The tag list as it's being edited, and the field a new one is typed into.
    @State private var inboxTags: [InboxTagStyle] = AppSettings.shared.inboxTags
    @State private var newTag = ""
    @FocusState private var deviceNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                microphoneSection
                displaySection
                speechModelSection
                languageModelSection
                presetsSection
                inboxTagsSection
                graphSection
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
            textSizeRow
        } header: {
            WWSectionHeader("Display")
        } footer: {
            WWFooter("When on, the screen rotates to landscape. Turn it off to lock the app to portrait. "
                     + "Text Size sets how big transcriptions are drawn — a document's paragraphs and "
                     + "an Inbox entry alike, at the size below; a graph node a little under it, being "
                     + "a card on a canvas — and the editor each of those becomes when you open it, "
                     + "so nothing changes size under your finger.")
        }
        .listRowBackground(WW.surface)
    }

    /// The transcription text size: a slider between the two ends of the range, the number itself,
    /// and a line of sample text set at whatever is currently chosen — the only honest preview.
    private var textSizeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Text Size")
                Spacer(minLength: 12)
                Text("\(Int(transcriptTextSize.rounded())) pt")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(WW.inkSecondary)
            }
            HStack(spacing: 12) {
                Text("A").font(.system(size: 13)).foregroundStyle(WW.inkTertiary)
                Slider(value: $transcriptTextSize,
                       in: AppSettings.transcriptTextSizeRange,
                       step: 1)
                    .accessibilityLabel("Text Size")
                    .accessibilityValue("\(Int(transcriptTextSize.rounded())) points")
                Text("A").font(.system(size: 22)).foregroundStyle(WW.inkTertiary)
            }
            Text("The quick brown fox jumps over the lazy dog.")
                .font(.system(size: transcriptTextSize))
                .lineSpacing(5)
                .foregroundStyle(WW.ink)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
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
            WWFooter("Rewrites transcripts. The on-device model (Liquid AI's LFM2.5 1.2B) downloads "
                     + "once while online and then works offline; it reloads automatically when you "
                     + "pick it (tap Remove Download to free its space). The online Claude models "
                     + "stream from Anthropic — pick one when you have a cell signal and tap "
                     + "Authenticate to add your API key (no download).")
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

    // MARK: Inbox tags

    /// The tags the Inbox files entries under. Kept here rather than in the Inbox itself because
    /// it's a list you set up once and then use for months — and because the Inbox's own screen is
    /// for the entries, not for the filing system.
    private var inboxTagsSection: some View {
        Section {
            ForEach($inboxTags) { $tag in
                HStack(spacing: 10) {
                    // The swatch is the control: tap it for the palette. Nothing else in the row
                    // does anything, so there's no doubt about what's tappable.
                    Menu {
                        Picker("Colour", selection: $tag.colorID) {
                            ForEach(InboxTag.paletteIDs, id: \.self) { id in
                                Label(colorName(id), systemImage: "circle.fill")
                                    .foregroundStyle(WW.tagColor(id))
                                    .tag(id)
                            }
                        }
                    } label: {
                        Circle()
                            .fill(WW.tagColor(tag.colorID))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Colour for \(tag.name)")
                    Text(tag.name).foregroundStyle(WW.ink)
                }
            }
            // `onDelete` belongs to the ForEach itself, so nothing may come between them.
            .onDelete { offsets in
                inboxTags.remove(atOffsets: offsets)
                AppSettings.shared.inboxTags = inboxTags
            }
            HStack(spacing: 10) {
                TextField("New tag", text: $newTag)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onSubmit(addTag)
                Button("Add", action: addTag)
                    .buttonStyle(.plain)
                    .foregroundStyle(canAddTag ? WW.moss : WW.inkTertiary)
                    .disabled(!canAddTag)
            }
        } header: {
            WWSectionHeader("Inbox Tags")
        } footer: {
            WWFooter("Swipe an Inbox entry right and tap Tag to file it under one of these. An entry "
                     + "whose first word *is* one of them — “Question…”, “Fixed…”, “Reminders…” — "
                     + "files itself the moment it's transcribed. Tap a colour to change it. Swipe a "
                     + "tag away and the entries filed under it keep saying so — and keep their "
                     + "filter — until they're filed somewhere else.")
        }
        // A colour picked through a row's binding writes straight into the array; this is where it
        // reaches the setting the rest of the app reads.
        .onChange(of: inboxTags) { _, tags in AppSettings.shared.inboxTags = tags }
        .listRowBackground(WW.surface)
    }

    private var canAddTag: Bool {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !inboxTags.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// A new tag takes the first colour none of the others is wearing, so it stands apart from them
    /// without anyone having to choose one.
    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddTag else { return }
        let color = InboxTag.nextColorID(notIn: inboxTags.map(\.colorID))
        inboxTags.append(InboxTagStyle(name: trimmed, colorID: color))
        AppSettings.shared.inboxTags = inboxTags
        newTag = ""
        wwLog("Added the Inbox tag “\(trimmed)”", .general)
    }

    /// What to call a colour in the picker — the palette's ids are for storage, not for reading.
    private func colorName(_ id: String) -> String {
        switch id {
        case "moss":   return "Moss"
        case "violet": return "Violet"
        case "amber":  return "Amber"
        case "slate":  return "Slate"
        case "ember":  return "Ember"
        case "ink":    return "Ink"
        default:       return id.capitalized
        }
    }

    // MARK: Graphs

    /// "Auto transform graph nodes" — the graph's answer to the toggle the Inbox and documents carry
    /// at the bottom of the screen. A graph's canvas runs all the way to the bottom edge, so the
    /// choice lives here instead, and applies to every graph.
    private var graphSection: some View {
        Section {
            Picker("Auto transform nodes", selection: $graphAutoTransformID) {
                Text("Off").tag(UUID?.none)
                ForEach(model.documents.presets) { preset in
                    Text(preset.name).tag(UUID?.some(preset.id))
                }
            }
            .onChange(of: graphAutoTransformID) { _, id in
                AppSettings.shared.graphAutoTransformPresetID = id
                let chosen = model.documents.presets.first { $0.id == id }
                wwLog("Auto transform for graph nodes " +
                      (chosen.map { "set to “\($0.name)”" } ?? "turned off"), .transform)
            }
        } header: {
            WWSectionHeader("Graphs")
        } footer: {
            WWFooter("Runs over every graph node the moment it's first transcribed, so spoken nodes "
                     + "arrive already cleaned up. Documents and the Inbox keep their own choice, at "
                     + "the bottom of each screen.")
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
