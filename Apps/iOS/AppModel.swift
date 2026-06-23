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

    /// 0...1 download progress per model while preparing; nil when idle/ready (the last value
    /// is retained on failure so the Settings bar shows where a download stalled).
    @Published var speechProgress: Double?
    @Published var llmProgress: Double?

    /// Active Watch-pairing window: the 5-digit code shown on screen and when it expires. Nil
    /// when not pairing. `lastPairedWatch` holds the name of the most recently paired Watch so
    /// the UI can confirm success.
    @Published var pairingCode: String?
    @Published var pairingEndsAt: Date?
    @Published var lastPairedWatch: String?

    private let pairingWindow: TimeInterval = 120

    #if canImport(WatchConnectivity)
    private let phone = PhoneSessionTransport()
    #endif
    private var localServer: LocalNetworkServer?
    private var bluetoothServer: BluetoothRecordingServer?
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

    /// Start both direct-from-Watch receivers: WiFi (`LocalNetworkServer`) and Bluetooth
    /// (`BluetoothRecordingServer`). A Watch with no network reaches the iPad over Bluetooth;
    /// on a shared WiFi it uses the faster local-network path. Whichever the Watch picked at
    /// pairing time is the one it uses.
    func startLocalServer() {
        let onPaired: @MainActor (String) -> Void = { [weak self] watchName in
            self?.lastPairedWatch = watchName
            self?.cancelWatchPairing()
            wwLog("Watch “\(watchName)” paired with this iPad", .transfer)
        }

        let server = LocalNetworkServer(port: AppSettings.shared.localServerPort,
                                        serviceName: AppSettings.shared.deviceDisplayName)
        server.expectedSecret = AppSettings.shared.pairingSecret
        server.onReceive = { [weak self] transfer, data in self?.ingest(transfer: transfer, data: data) }
        server.onPairSuccess = onPaired
        do {
            try server.start()
            localServer = server
            wwLog("Local receive server started (port \(AppSettings.shared.localServerPort))", .transfer)
        } catch {
            setupError = "Couldn't start local server: \(error.localizedDescription)"
            wwLog("Local server failed to start: \(error.localizedDescription)", .error)
        }

        let ble = BluetoothRecordingServer(serviceName: AppSettings.shared.deviceDisplayName)
        ble.expectedSecret = AppSettings.shared.pairingSecret
        ble.onReceive = { [weak self] transfer, data in self?.ingest(transfer: transfer, data: data) }
        ble.onPairSuccess = onPaired
        try? ble.start()
        bluetoothServer = ble
        wwLog("Bluetooth receive server started", .transfer)
    }

    func stopLocalServer() {
        localServer?.stop()
        localServer = nil
        bluetoothServer?.stop()
        bluetoothServer = nil
        wwLog("Receive servers stopped", .transfer)
    }

    // MARK: Watch pairing

    /// Open a pairing window: ensure the local server is running, show a fresh 5-digit code, and
    /// arm the server to accept a Watch presenting that code. The window closes automatically
    /// when a Watch pairs or after `pairingWindow` seconds.
    func beginWatchPairing() {
        if !AppSettings.shared.localServerEnabled {
            AppSettings.shared.localServerEnabled = true
        }
        if localServer == nil { startLocalServer() }

        let code = String(format: "%05d", Int.random(in: 0...99_999))
        pairingCode = code
        pairingEndsAt = Date().addingTimeInterval(pairingWindow)
        lastPairedWatch = nil
        let token = AppSettings.shared.pairingSecret
        localServer?.beginPairing(code: code, token: token, duration: pairingWindow)
        bluetoothServer?.beginPairing(code: code, token: token, duration: pairingWindow)
        wwLog("Watch pairing window opened (code \(code))", .transfer)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(pairingWindow * 1_000_000_000))
            guard let self, self.pairingCode == code else { return }
            self.cancelWatchPairing()
            wwLog("Watch pairing window expired", .transfer)
        }
    }

    func cancelWatchPairing() {
        pairingCode = nil
        pairingEndsAt = nil
        localServer?.endPairing()
        bluetoothServer?.endPairing()
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

    func prepareModels() async {
        busyMessage = "Preparing speech model…"
        wwLog("Preparing speech model (Parakeet TDT v3)… downloading on first run", .model)
        let speechStart = Date()
        if !transcriptionReady {
            speechProgress = 0
            do {
                try await transcription.prepare { [weak self] frac in
                    Task { @MainActor in self?.speechProgress = frac }
                }
                transcriptionReady = await transcription.isReady
                speechProgress = nil
                wwLog(String(format: "Speech model ready in %.1fs", Date().timeIntervalSince(speechStart)), .model)
            } catch {
                setupError = error.localizedDescription      // keep speechProgress to show stall point
                wwLog("Speech model failed: \(error.localizedDescription)", .error)
            }
        }

        busyMessage = "Preparing language model… (this can take a while)"
        wwLog("Preparing language model (\(AppSettings.shared.model.displayName))… downloading on first run", .model)
        let llmStart = Date()
        if !modelReady {
            llmProgress = 0
            do {
                try await transform.prepare { [weak self] frac in
                    Task { @MainActor in self?.llmProgress = frac }
                }
                modelReady = await transform.isReady
                llmProgress = nil
                wwLog(String(format: "Language model ready in %.1fs", Date().timeIntervalSince(llmStart)), .model)
            } catch {
                setupError = error.localizedDescription      // keep llmProgress to show stall point
                wwLog("Language model failed: \(error.localizedDescription)", .error)
            }
        }
        busyMessage = nil

        if transcriptionReady { transcribePending() }   // catch up anything captured during download
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
