import Foundation
import SwiftUI
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

    init() {
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
        } catch {
            setupError = "Couldn't start local server: \(error.localizedDescription)"
        }
    }

    func stopLocalServer() {
        localServer?.stop()
        localServer = nil
    }

    private func ingest(transfer: RecordingTransfer, data: Data) {
        do {
            try recordings.ingest(audio: data, recording: transfer.recording)
        } catch {
            setupError = "Failed to save incoming recording: \(error.localizedDescription)"
        }
    }

    // MARK: Setup (one-time, online)

    /// Download and load both models. Must run once with internet; offline thereafter.
    func prepareModels() async {
        busyMessage = "Preparing speech model…"
        do {
            try await transcription.prepare()
            transcriptionReady = await transcription.isReady
        } catch {
            setupError = error.localizedDescription
        }

        busyMessage = "Preparing language model… (this can take a while)"
        do {
            try await transform.prepare()
            modelReady = await transform.isReady
        } catch {
            setupError = error.localizedDescription
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
        do {
            let url = recordings.audioURL(for: recording)
            let result = try await transcription.transcribe(audioFileAt: url)
            let doc = Document(
                title: recording.name,
                sourceRecordingID: recording.id,
                transcript: result.text
            )
            documents.add(doc)
            return doc
        } catch {
            setupError = error.localizedDescription
            return nil
        }
    }

    /// Run a preset against a document, appending the result as a transformation.
    func runTransformation(_ preset: PromptPreset,
                           on document: Document,
                           source: String,
                           onToken: (@Sendable (String) -> Void)? = nil) async {
        do {
            let output = try await transform.transform(transcript: source,
                                                       with: preset,
                                                       onToken: onToken)
            let t = Document.Transformation(presetName: preset.name,
                                            presetID: preset.id,
                                            output: output)
            documents.appendTransformation(t, to: document.id)
        } catch {
            setupError = error.localizedDescription
        }
    }
}
