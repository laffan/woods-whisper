import SwiftUI
import WoodsWhisperKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedModel = AppSettings.shared.model
    @State private var selectedSpeechModel = AppSettings.shared.speechModel
    @State private var localServerEnabled = AppSettings.shared.localServerEnabled
    @State private var micOptions: [AudioRecorder.InputOption] = []
    @State private var selectedMicUID: String? = AppSettings.shared.preferredMicUID

    var body: some View {
        NavigationStack {
            Form {
                microphoneSection
                speechModelSection
                languageModelSection
                presetsSection
                connectivitySection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear { micOptions = AudioRecorder.availableInputs() }
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
            Text("Microphone")
        } footer: {
            Text("Choose which microphone to record with — built-in, wired, or Bluetooth. "
                 + "“Automatic” lets the system pick (usually the most recently connected).")
        }
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
                .font(.caption).foregroundStyle(.secondary)

            ModelSetupRow(title: "Speech weights", systemImage: "waveform",
                          ready: model.transcriptionReady, progress: model.speechProgress)
            if !model.transcriptionReady {
                Button(downloadTitle(preparing: model.isPreparingSpeech,
                                     started: model.speechProgress != nil)) {
                    Task { await model.prepareSpeechModel() }
                }
                .disabled(model.isPreparingSpeech)
            }
        } header: {
            Text("Speech Model")
        } footer: {
            Text("Transcribes recordings to text on-device. Parakeet is the most accurate; the "
                 + "smaller Whisper models are lighter, faster downloads. Download once while "
                 + "online; works offline afterward. Switching model requires downloading it.")
        }
    }

    // MARK: Language model

    private var languageModelSection: some View {
        Section {
            Picker("Model", selection: $selectedModel) {
                ForEach(LanguageModelChoice.allCases) { m in
                    Text(m.pickerLabel).tag(m)
                }
            }
            .onChange(of: selectedModel) { _, newValue in
                AppSettings.shared.model = newValue
                Task {
                    do { try await model.transform.setModel(newValue) }
                    catch { model.setupError = error.localizedDescription }
                    await model.refreshReadiness()
                }
            }

            ModelSetupRow(title: "Model weights", systemImage: "brain",
                          ready: model.modelReady, progress: model.llmProgress)
            if !model.modelReady {
                if model.isPreparingLLM {
                    Button("Cancel Download", role: .destructive) {
                        model.cancelLanguageModelDownload()
                    }
                } else {
                    Button(downloadTitle(preparing: false,
                                         started: model.llmProgress != nil)) {
                        model.startLanguageModelDownload()
                    }
                }
            }
        } header: {
            Text("Language Model")
        } footer: {
            Text("Rewrites transcripts on-device (Qwen3, Llama 3.2, or Gemma 3). Download once "
                 + "while online (a few GB depending on model); works offline afterward, and "
                 + "reloads automatically on launch. If interrupted, tap to resume. Switching "
                 + "model requires downloading it.")
        }
    }

    /// Download button label: idle → "Download", interrupted → "Resume", in-flight → "Downloading…".
    private func downloadTitle(preparing: Bool, started: Bool) -> String {
        if preparing { return "Downloading…" }
        return started ? "Resume Download" : "Download"
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section("Prompt Presets") {
            NavigationLink {
                PresetListView()
            } label: {
                Label("Manage Presets (\(model.documents.presets.count))", systemImage: "wand.and.stars")
            }
        }
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
            Text("Connectivity")
        } footer: {
            Text("On iPad, enable this to let an iPhone-free Watch send recordings — over WiFi "
                 + "when both share a network, or Bluetooth when off-grid with no WiFi. On iPhone, "
                 + "the paired Watch connects automatically.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Device name", value: AppSettings.shared.deviceDisplayName)
            Text("Woods Whisper — offline voice capture, transcription, and transformation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct StatusDot: View {
    let ready: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ready ? .green : .orange).frame(width: 10, height: 10)
            Text(ready ? "Ready" : "Not ready").font(.caption).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                } else {
                    StatusDot(ready: ready)
                }
            }
            if let progress {
                ProgressView(value: progress.fractionCompleted)
                if let summary = progress.byteSummary ?? progress.detail {
                    Text(summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
