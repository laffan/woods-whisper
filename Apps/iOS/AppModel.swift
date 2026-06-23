import Foundation
import SwiftUI
import Combine
import WoodsWhisperKit

/// Top-level coordinator for the iOS/iPadOS app. Owns the document store and on-device
/// services, wires up the inbound receivers (WatchConnectivity from the paired Watch, and the
/// local-network server for direct Watch→iPad), and exposes high-level actions to the UI.
///
/// Documents are topic containers holding one or more recordings; each recording is
/// transcribed automatically (on capture, or on arrival from the Watch). Transformations run
/// over a document's combined transcript.
@MainActor
final class AppModel: ObservableObject {
    let documents = DocumentStore()

    let transcription: TranscriptionService = ParakeetTranscriptionService()
    let transform: TextTransformService = GemmaTransformService(model: AppSettings.shared.model)

    @Published var transcriptionReady = false
    @Published var modelReady = false
    @Published var setupError: String?
    @Published var busyMessage: String?

    /// Download progress per model while preparing; nil when idle/ready (the last value is
    /// retained on failure so the Settings bar shows where a download stalled).
    @Published var speechProgress: DownloadProgress?
    @Published var llmProgress: DownloadProgress?

    /// In-flight flags so each model's Download button can be disabled independently.
    @Published var isPreparingSpeech = false
    @Published var isPreparingLLM = false

    #if canImport(WatchConnectivity)
    private let phone = PhoneSessionTransport()
    #endif
    private var localServer: LocalNetworkServer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // DocumentStore is a separate ObservableObject; forward its changes so views observing
        // AppModel re-render on async updates (e.g. a recording arriving from the Watch).
        documents.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        configureReceivers()
    }

    // MARK: Receivers

    private func configureReceivers() {
        #if os(iOS)
        phone.onReceive = { [weak self] transfer, data in
            self?.ingest(transfer: transfer, data: data)
        }
        try? phone.start()
        #endif

        if AppSettings.shared.localServerEnabled {
            startLocalServer()
        }
    }

    func startLocalServer() {
        let server = LocalNetworkServer(port: AppSettings.shared.localServerPort,
                                        serviceName: AppSettings.shared.deviceDisplayName)
        server.expectedSecret = AppSettings.shared.pairingSecret
        server.onReceive = { [weak self] transfer, data in
            self?.ingest(transfer: transfer, data: data)
        }
        do {
            try server.start()
            localServer = server
            wwLog("Local receive server started (port \(AppSettings.shared.localServerPort))", .transfer)
        } catch {
            setupError = "Couldn't start local server: \(error.localizedDescription)"
            wwLog("Local server failed to start: \(error.localizedDescription)", .error)
        }
    }

    func stopLocalServer() {
        localServer?.stop()
        localServer = nil
        wwLog("Local receive server stopped", .transfer)
    }

    /// A recording arrived from the Watch: file it in the Inbox document and auto-transcribe.
    private func ingest(transfer: RecordingTransfer, data: Data) {
        let kb = Double(data.count) / 1024
        wwLog(String(format: "Received recording “%@” (%.0f KB) from %@", transfer.recording.name,
                     kb, transfer.recording.origin.rawValue), .transfer)
        var recording = transfer.recording
        recording.status = .pending
        let inbox = documents.inboxDocument()
        documents.addRecording(recording, audioData: data, toDocument: inbox.id)
        wwLog("Filed “\(recording.name)” into \(inbox.title)", .transfer)
        autoTranscribe(recordingID: recording.id, inDocument: inbox.id)
    }

    // MARK: Capture on this device

    /// Register a clip just recorded on this device (audio already written to `audioURL`) into
    /// `documentID`, then auto-transcribe it.
    func addDeviceRecording(fileName: String, duration: TimeInterval, toDocument documentID: UUID) {
        let recording = Recording(duration: duration, audioFileName: fileName, origin: deviceOrigin())
        documents.addRecording(recording, toDocument: documentID)
        wwLog("Captured “\(recording.name)” on device", .general)
        autoTranscribe(recordingID: recording.id, inDocument: documentID)
    }

    private func deviceOrigin() -> Recording.Origin {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #else
        return .phone
        #endif
    }

    // MARK: Transcription

    /// Kick off transcription for a recording if the speech model is ready; otherwise leave it
    /// pending (it'll be picked up after setup completes).
    func autoTranscribe(recordingID: UUID, inDocument documentID: UUID) {
        guard transcriptionReady else {
            wwLog("Speech model not ready yet — “\(recordingID)” left pending", .transcription)
            return
        }
        Task { await transcribe(recordingID: recordingID, inDocument: documentID) }
    }

    func transcribe(recordingID: UUID, inDocument documentID: UUID) async {
        guard var recording = documents.document(with: documentID)?
            .recordings.first(where: { $0.id == recordingID }) else { return }

        recording.status = .transcribing
        documents.updateRecording(recording, inDocument: documentID)
        wwLog("Transcribing “\(recording.name)”…", .transcription)
        let start = Date()
        do {
            let url = documents.audioURL(for: recording)
            let result = try await transcription.transcribe(audioFileAt: url)
            recording.transcript = result.text
            recording.status = .done
            documents.updateRecording(recording, inDocument: documentID)
            wwLog(String(format: "Transcribed “%@” in %.1fs (%d chars)", recording.name,
                         Date().timeIntervalSince(start), result.text.count), .transcription)
        } catch {
            recording.status = .failed
            documents.updateRecording(recording, inDocument: documentID)
            setupError = error.localizedDescription
            wwLog("Transcription failed for “\(recording.name)”: \(error.localizedDescription)", .error)
        }
    }

    /// Transcribe everything still pending/failed — used once the model becomes ready.
    func transcribePending() {
        for document in documents.documents {
            for recording in document.recordings where recording.status == .pending || recording.status == .failed {
                Task { await transcribe(recordingID: recording.id, inDocument: document.id) }
            }
        }
    }

    // MARK: Setup (one-time, online)

    /// Download/prepare both models in sequence (used by "prepare everything" flows).
    func prepareModels() async {
        await prepareSpeechModel()
        await prepareLanguageModel()
    }

    /// Download/prepare the Parakeet speech model. Safe to call repeatedly; no-op if ready.
    func prepareSpeechModel() async {
        guard !isPreparingSpeech, !transcriptionReady else { return }
        isPreparingSpeech = true
        busyMessage = "Preparing speech model…"
        speechProgress = DownloadProgress(fractionCompleted: 0)
        wwLog("Speech model (Parakeet TDT v3): preparing — downloads on first run", .model)
        let start = Date()
        do {
            try await transcription.prepare { [weak self] p in
                Task { @MainActor in self?.speechProgress = p }
            }
            transcriptionReady = await transcription.isReady
            speechProgress = nil
            wwLog(String(format: "Speech model ready in %.1fs", Date().timeIntervalSince(start)), .model)
            transcribePending()   // catch up anything captured during download
        } catch {
            setupError = error.localizedDescription      // keep speechProgress to show stall point
            wwLog("Speech model failed: \(error.localizedDescription)", .error)
        }
        isPreparingSpeech = false
        if !isPreparingLLM { busyMessage = nil }
    }

    /// Download/prepare the selected Gemma language model. Safe to call repeatedly.
    func prepareLanguageModel() async {
        guard !isPreparingLLM, !modelReady else { return }
        isPreparingLLM = true
        busyMessage = "Preparing language model… (this can take a while)"
        llmProgress = DownloadProgress(fractionCompleted: 0)
        wwLog("Language model (\(AppSettings.shared.model.displayName)): preparing — downloads on first run", .model)
        let start = Date()
        do {
            try await transform.prepare { [weak self] p in
                Task { @MainActor in self?.llmProgress = p }
            }
            modelReady = await transform.isReady
            llmProgress = nil
            wwLog(String(format: "Language model ready in %.1fs", Date().timeIntervalSince(start)), .model)
        } catch {
            setupError = error.localizedDescription      // keep llmProgress to show stall point
            wwLog("Language model failed: \(error.localizedDescription)", .error)
        }
        isPreparingLLM = false
        if !isPreparingSpeech { busyMessage = nil }
    }

    func refreshReadiness() async {
        transcriptionReady = await transcription.isReady
        modelReady = await transform.isReady
        if transcriptionReady { transcribePending() }
    }

    // MARK: Transform

    /// Run a preset against a document's combined transcript, appending the result.
    func runTransformation(_ preset: PromptPreset,
                           on document: Document,
                           onToken: (@Sendable (String) -> Void)? = nil) async {
        let source = document.combinedTranscript
        guard !source.isEmpty else {
            setupError = "Nothing to transform yet — record and transcribe something first."
            return
        }
        wwLog("Running preset “\(preset.name)” on “\(document.title)”…", .transform)
        let start = Date()
        do {
            let output = try await transform.transform(transcript: source, with: preset, onToken: onToken)
            let t = Document.Transformation(presetName: preset.name, presetID: preset.id, output: output)
            documents.appendTransformation(t, to: document.id)
            wwLog(String(format: "Preset “%@” finished in %.1fs (%d chars)", preset.name,
                         Date().timeIntervalSince(start), output.count), .transform)
        } catch {
            setupError = error.localizedDescription
            wwLog("Transform failed: \(error.localizedDescription)", .error)
        }
    }
}
