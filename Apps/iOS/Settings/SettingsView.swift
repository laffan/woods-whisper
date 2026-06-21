import SwiftUI
import WoodsWhisperKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedModel = AppSettings.shared.model
    @State private var localServerEnabled = AppSettings.shared.localServerEnabled

    var body: some View {
        NavigationStack {
            Form {
                setupSection
                modelSection
                presetsSection
                connectivitySection
                aboutSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: One-time setup

    private var setupSection: some View {
        Section {
            HStack {
                Label("Speech model (Parakeet)", systemImage: "waveform")
                Spacer()
                StatusDot(ready: model.transcriptionReady)
            }
            HStack {
                Label("Language model (Gemma)", systemImage: "brain")
                Spacer()
                StatusDot(ready: model.modelReady)
            }
            Button("Download / Prepare Models") {
                Task { await model.prepareModels() }
            }
            .disabled(model.busyMessage != nil)
        } header: {
            Text("Setup")
        } footer: {
            Text("Run once while connected to the internet. Everything works offline afterward.")
        }
    }

    // MARK: Model selection

    private var modelSection: some View {
        Section("Language Model") {
            Picker("Model", selection: $selectedModel) {
                ForEach(GemmaModel.allCases) { m in
                    Text(m.displayName).tag(m)
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
            Text(selectedModel.approxRAMNote)
                .font(.caption).foregroundStyle(.secondary)
        }
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
                    Label("Watch Pairing Details", systemImage: "qrcode")
                }
            }
        } header: {
            Text("Connectivity")
        } footer: {
            Text("On iPad, enable this to let an iPhone-free Watch send recordings over WiFi. "
                 + "On iPhone, the paired Watch connects automatically.")
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
