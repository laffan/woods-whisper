import Foundation
import SwiftUI
import Combine
import WoodsWhisperKit

/// Top-level coordinator for the iOS/iPadOS app. Owns the stores and on-device services,
/// wires up the inbound receivers (WatchConnectivity from iPhone-paired Watch, and the
/// local-network server for direct Watch→iPad), and exposes high-level actions to the UI.
@MainActor
final class AppModel: ObservableObject {
    let recordings = RecordingStore()
    let documents = DocumentStore()

    let transcription: TranscriptionService = ParakeetTranscriptionService()
    let transform: TextTransformService = GemmaTransformService(model: AppSettings.shared.model)

    @Published var transcriptionReady = false
    @Published var modelReady = false
    @Published var setupError: String?
    @Published var busyMessage: String?

    // Inbound transports.
    #if canImport(WatchConnectivity)
    private let phone = PhoneSessionTransport()
    #endif
    private var localServer: LocalNetworkServer?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // The stores are separate ObservableObjects; forward their changes so views observing
        // AppModel re-render when recordings/documents change (e.g. a recording arriving from
        // the Watch asynchronously, which otherwise wouldn't refresh the list until relaunch).
        recordings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        documents.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        configureReceivers()
    }

    // MARK: Receivers

    private func configureReceivers() {
        #if os(iOS)
        // iPhone companion path: receive from the paired Watch via WatchConnectivity.
        phone.onReceive = { [weak self] transfer, data in
            self?.ingest(transfer: transfer, data: data)
        }
        try? phone.start()
        #endif

        // Direct Watch→iPad path: run a local server if enabled in settings.
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

    private func ingest(transfer: RecordingTransfer, data: Data) {
        let kb = Double(data.count) / 1024
        wwLog(String(format: "Received recording “%@” (%.0f KB) from %@", transfer.recording.name,
                     kb, transfer.recording.origin.rawValue), .transfer)
        do {
            try recordings.ingest(audio: data, recording: transfer.recording)
            wwLog("Saved incoming recording “\(transfer.recording.name)”", .transfer)
        } catch {
            setupError = "Failed to save incoming recording: \(error.localizedDescription)"
            wwLog("Failed to save incoming recording: \(error.localizedDescription)", .error)
        }
    }

    // MARK: Setup (one-time, online)

    /// Download and load both models. Must run once with internet; offline thereafter.
    func prepareModels() async {
        busyMessage = "Preparing speech model…"
        wwLog("Preparing speech model (Parakeet TDT v3)… downloading on first run", .model)
        let speechStart = Date()
        do {
            try await transcription.prepare()
            transcriptionReady = await transcription.isReady
            wwLog(String(format: "Speech model ready in %.1fs", Date().timeIntervalSince(speechStart)), .model)
        } catch {
            setupError = error.localizedDescription
            wwLog("Speech model failed: \(error.localizedDescription)", .error)
        }

        busyMessage = "Preparing language model… (this can take a while)"
        wwLog("Preparing language model (\(AppSettings.shared.model.displayName))… downloading on first run", .model)
        let llmStart = Date()
        do {
            try await transform.prepare()
            modelReady = await transform.isReady
            wwLog(String(format: "Language model ready in %.1fs", Date().timeIntervalSince(llmStart)), .model)
        } catch {
            setupError = error.localizedDescription
            wwLog("Language model failed: \(error.localizedDescription)", .error)
        }
        busyMessage = nil
    }

    func refreshReadiness() async {
        transcriptionReady = await transcription.isReady
        modelReady = await transform.isReady
    }

    // MARK: Recording → Document pipeline

    /// Transcribe a recording into a new Document.
    @discardableResult
    func transcribeToDocument(_ recording: Recording) async -> Document? {
        busyMessage = "Transcribing…"
        defer { busyMessage = nil }
        wwLog("Transcribing “\(recording.name)”…", .transcription)
        let start = Date()
        do {
            let url = recordings.audioURL(for: recording)
            let result = try await transcription.transcribe(audioFileAt: url)
            let doc = Document(
                title: recording.name,
                sourceRecordingID: recording.id,
                transcript: result.text
            )
            documents.add(doc)
            wwLog(String(format: "Transcribed “%@” in %.1fs (%d chars)", recording.name,
                         Date().timeIntervalSince(start), result.text.count), .transcription)
            return doc
        } catch {
            setupError = error.localizedDescription
            wwLog("Transcription failed: \(error.localizedDescription)", .error)
            return nil
        }
    }

    /// Run a preset against a document, appending the result as a transformation.
    func runTransformation(_ preset: PromptPreset,
                           on document: Document,
                           source: String,
                           onToken: (@Sendable (String) -> Void)? = nil) async {
        wwLog("Running preset “\(preset.name)” on “\(document.title)”…", .transform)
        let start = Date()
        do {
            let output = try await transform.transform(transcript: source,
                                                       with: preset,
                                                       onToken: onToken)
            let t = Document.Transformation(presetName: preset.name,
                                            presetID: preset.id,
                                            output: output)
            documents.appendTransformation(t, to: document.id)
            wwLog(String(format: "Preset “%@” finished in %.1fs (%d chars)", preset.name,
                         Date().timeIntervalSince(start), output.count), .transform)
        } catch {
            setupError = error.localizedDescription
            wwLog("Transform failed: \(error.localizedDescription)", .error)
        }
    }
}
