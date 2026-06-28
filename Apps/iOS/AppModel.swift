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

    let transcription: TranscriptionService = SpeechTranscriptionCoordinator(model: AppSettings.shared.speechModel)
    private let languageModels = LanguageModelCoordinator(model: AppSettings.shared.model)
    var transform: TextTransformService { languageModels }

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

    /// The user-initiated language-model download, kept so it can be cancelled.
    private var llmPrepareTask: Task<Void, Never>?

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

        AudioRecorder.preferredInputUID = AppSettings.shared.preferredMicUID
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
    /// `documentID`'s Recordings section, auto-transcribe it, and place the transcript into the
    /// document body per `body` (`.append` for the in-document "Add Recording", `.at` for the
    /// inter-paragraph "+", `.none` for the Inbox where there is no body).
    func addDeviceRecording(audioURL: URL, duration: TimeInterval, toDocument documentID: UUID,
                            body: BodyInsertion = .none) {
        let name = Recording.defaultName(for: Date(), duration: duration,
                                         byteCount: Recording.fileSize(at: audioURL))
        let recording = Recording(name: name, duration: duration,
                                  audioFileName: audioURL.lastPathComponent, origin: deviceOrigin())
        documents.addRecording(recording, toDocument: documentID)
        wwLog("Captured “\(recording.name)” on device", .general)
        guard transcriptionReady else {
            if body != .none {
                setupError = "Speech model isn't ready yet — the recording was saved; transcribe it once setup finishes."
            }
            return   // left pending; picked up by transcribePending after setup
        }
        Task {
            await transcribe(recordingID: recording.id, inDocument: documentID)
            guard body != .none,
                  let text = documents.document(with: documentID)?
                    .recordings.first(where: { $0.id == recording.id })?.transcript,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            switch body {
            case .none:           break
            case .append:         documents.appendParagraph(text, to: documentID)
            case .at(let position): documents.insertParagraph(text, at: position, in: documentID)
            }
        }
    }

    /// Where a freshly captured recording's transcript should land in the document body.
    enum BodyInsertion: Equatable {
        case none          // Inbox: no body
        case append        // add to the end of the body
        case at(Int)       // insert at a specific paragraph index
    }

    /// Capture a clip (into the Recordings section), transcribe it, and replace the text of an
    /// existing body paragraph with the result. Backs a paragraph's "Replace" swipe action.
    func captureReplacingParagraph(audioURL: URL, duration: TimeInterval,
                                   paragraphID: UUID, in documentID: UUID) {
        let name = Recording.defaultName(for: Date(), duration: duration,
                                         byteCount: Recording.fileSize(at: audioURL))
        let recording = Recording(name: name, duration: duration,
                                  audioFileName: audioURL.lastPathComponent, origin: deviceOrigin())
        documents.addRecording(recording, toDocument: documentID)
        guard transcriptionReady else {
            setupError = "Speech model isn't ready yet — the recording was saved; transcribe it once setup finishes."
            return
        }
        Task {
            await transcribe(recordingID: recording.id, inDocument: documentID)
            if let text = documents.document(with: documentID)?
                .recordings.first(where: { $0.id == recording.id })?.transcript,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                documents.replaceParagraph(paragraphID, in: documentID, withTextSplitInto: text)
            }
        }
    }

    /// "Re-record": replace a recording's audio with a freshly captured clip and re-transcribe it
    /// in place (the document body is left untouched — recordings are source material).
    func rerecordRecording(_ recordingID: UUID, in documentID: UUID,
                           audioURL: URL, duration: TimeInterval) {
        documents.replaceRecordingAudio(recordingID, in: documentID,
                                        newFileName: audioURL.lastPathComponent, duration: duration)
        autoTranscribe(recordingID: recordingID, inDocument: documentID)
    }

    /// "Reset with Originals": rebuild the document body from the recordings' own transcripts, one
    /// paragraph per recording, discarding any edits/transforms.
    func resetWithOriginals(in documentID: UUID) {
        guard let doc = documents.document(with: documentID) else { return }
        let paragraphs = doc.recordings.compactMap { recording -> Document.Paragraph? in
            let text = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : Document.Paragraph(text: text)
        }
        documents.setParagraphs(paragraphs, in: documentID)
        wwLog("Reset “\(doc.title)” to original transcripts (\(paragraphs.count) paragraphs)", .general)
    }

    /// "Re-transcribe": re-run speech-to-text on a recording, then append the resulting transcript
    /// as a new paragraph at the bottom of the document body.
    func retranscribeIntoBody(recordingID: UUID, in documentID: UUID) async {
        await transcribe(recordingID: recordingID, inDocument: documentID)
        guard let text = documents.document(with: documentID)?
            .recordings.first(where: { $0.id == recordingID })?.transcript,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        documents.appendParagraph(text, to: documentID)
    }

    /// "Append": add the recording's transcript as a new paragraph at the bottom of the document
    /// body. If the recording hasn't been transcribed yet, transcribe it first. (Unlike
    /// `retranscribeIntoBody`, this reuses an existing transcript rather than always re-running STT.)
    func appendRecordingToBody(recordingID: UUID, in documentID: UUID) {
        func currentTranscript() -> String {
            documents.document(with: documentID)?
                .recordings.first(where: { $0.id == recordingID })?.transcript?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        Task {
            if currentTranscript().isEmpty {
                await transcribe(recordingID: recordingID, inDocument: documentID)
            }
            let text = currentTranscript()
            guard !text.isEmpty else { return }
            documents.appendParagraph(text, to: documentID)
        }
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

    /// Download/prepare the speech model. Safe to call repeatedly; no-op if ready. When the model
    /// is already downloaded this loads it from cache rather than re-downloading.
    func prepareSpeechModel() async {
        guard !isPreparingSpeech, !transcriptionReady else { return }
        let cached = AppSettings.shared.isModelDownloaded(AppSettings.shared.speechModel.rawValue)
        isPreparingSpeech = true
        busyMessage = cached ? "Loading speech model…" : "Preparing speech model…"
        speechProgress = DownloadProgress(fractionCompleted: 0)
        wwLog("Speech model (\(AppSettings.shared.speechModel.displayName)): \(cached ? "loading from cache" : "preparing — downloads on first run")", .model)
        let start = Date()
        do {
            try await transcription.prepare { [weak self] p in
                Task { @MainActor in self?.speechProgress = p }
            }
            transcriptionReady = await transcription.isReady
            speechProgress = nil
            if transcriptionReady { AppSettings.shared.markModelDownloaded(AppSettings.shared.speechModel.rawValue) }
            wwLog(String(format: "Speech model ready in %.1fs", Date().timeIntervalSince(start)), .model)
            transcribePending()   // catch up anything captured during download
        } catch {
            setupError = error.localizedDescription      // keep speechProgress to show stall point
            wwLog("Speech model failed: \(error.localizedDescription)", .error)
        }
        isPreparingSpeech = false
        if !isPreparingLLM { busyMessage = nil }
    }

    /// Download/prepare the selected language model. Safe to call repeatedly. When the model is
    /// already downloaded this loads it from cache (fast, and works offline).
    func prepareLanguageModel() async {
        guard !isPreparingLLM, !modelReady else { return }
        let cached = AppSettings.shared.isModelDownloaded(AppSettings.shared.model.rawValue)
        isPreparingLLM = true
        busyMessage = cached ? "Loading language model…" : "Preparing language model… (this can take a while)"
        llmProgress = DownloadProgress(fractionCompleted: 0)
        wwLog("Language model (\(AppSettings.shared.model.displayName)): \(cached ? "loading from cache" : "preparing — downloads on first run")", .model)
        let start = Date()
        do {
            try await transform.prepare { [weak self] p in
                Task { @MainActor in self?.llmProgress = p }
            }
            modelReady = await transform.isReady
            llmProgress = nil
            if modelReady { AppSettings.shared.markModelDownloaded(AppSettings.shared.model.rawValue) }
            wwLog(String(format: "Language model ready in %.1fs", Date().timeIntervalSince(start)), .model)
        } catch {
            if Task.isCancelled {
                llmProgress = nil                        // user cancelled — not an error
                wwLog("Language model download cancelled", .model)
            } else {
                setupError = error.localizedDescription   // keep llmProgress to show stall point
                wwLog("Language model failed: \(error.localizedDescription)", .error)
            }
        }
        isPreparingLLM = false
        if !isPreparingSpeech { busyMessage = nil }
    }

    // MARK: Language-model selection

    /// Switch the active language model. On-device models that were previously downloaded load
    /// automatically from cache (no need to re-tap Download); online models become ready as soon
    /// as an API key is present. Backs the Settings model picker.
    func selectLanguageModel(_ choice: LanguageModelChoice) {
        AppSettings.shared.model = choice
        Task {
            do { try await transform.setModel(choice) }
            catch { setupError = error.localizedDescription }
            await refreshReadiness()
            if !choice.isOnline, !modelReady, AppSettings.shared.isModelDownloaded(choice.rawValue) {
                await prepareLanguageModel()   // reload the cached weights for an on-device model
            }
        }
    }

    /// Whether the active on-device model's weights are downloaded (drives "Download" vs "Remove
    /// Download"). Always false for online models, which have nothing on disk.
    var isLanguageModelDownloaded: Bool {
        let choice = AppSettings.shared.model
        return !choice.isOnline && AppSettings.shared.isModelDownloaded(choice.rawValue)
    }

    /// Delete the active on-device model's downloaded weights and forget the download. Backs the
    /// Settings "Remove Download" button.
    func removeLanguageModelDownload() {
        let choice = AppSettings.shared.model
        languageModels.removeActiveDownload()
        AppSettings.shared.unmarkModelDownloaded(choice.rawValue)
        llmProgress = nil
        modelReady = false
    }

    // MARK: Online (Anthropic) authentication

    /// Whether an Anthropic API key has been saved (the online model's "is it set up?" state).
    var isAuthenticated: Bool { AnthropicAPIKeyStore.hasKey }

    /// Save (or clear) the Anthropic API key, then refresh readiness so the online model becomes
    /// usable immediately without re-selecting it.
    func saveAnthropicAPIKey(_ key: String) {
        AnthropicAPIKeyStore.setKey(key)
        wwLog("Anthropic API key \(AnthropicAPIKeyStore.hasKey ? "saved" : "cleared")", .model)
        Task { await refreshReadiness() }
    }

    /// Start the language-model download as a cancellable task (used by the Settings Download button).
    func startLanguageModelDownload() {
        guard llmPrepareTask == nil else { return }
        llmPrepareTask = Task { [weak self] in
            await self?.prepareLanguageModel()
            self?.llmPrepareTask = nil
        }
    }

    /// Cancel an in-flight language-model download.
    func cancelLanguageModelDownload() {
        llmPrepareTask?.cancel()
    }

    func refreshReadiness() async {
        transcriptionReady = await transcription.isReady
        modelReady = await transform.isReady
        if transcriptionReady { transcribePending() }
    }

    /// Reload any model that was downloaded in a previous session. Model readiness is in-memory on
    /// the services, so it's false on every launch even though the weights are cached on disk; this
    /// loads them back automatically (with the busy banner) so the user doesn't re-tap Download.
    /// Called once at startup.
    func loadDownloadedModelsAtStartup() async {
        await refreshReadiness()
        // Speech first, so transcription (and Retranscribe) work immediately; both are loads from
        // cache when previously downloaded.
        if !transcriptionReady, AppSettings.shared.isModelDownloaded(AppSettings.shared.speechModel.rawValue) {
            await prepareSpeechModel()
        }
        if !modelReady, AppSettings.shared.isModelDownloaded(AppSettings.shared.model.rawValue) {
            await prepareLanguageModel()
        }
    }

    // MARK: Transform

    /// Run a preset against the document's whole body, replacing it with the transformed text
    /// (split back into paragraphs) rather than appending a new block.
    func transformDocument(_ preset: PromptPreset,
                           on document: Document,
                           onToken: (@Sendable (TransformToken) -> Void)? = nil) async {
        let source = document.combinedText
        guard !source.isEmpty else {
            setupError = "Nothing to transform yet — record and transcribe something first."
            return
        }
        wwLog("Transforming “\(document.title)” with “\(preset.name)”…", .transform)
        let start = Date()
        do {
            let result = try await transform.transform(transcript: source, with: preset, onToken: onToken)
            documents.setParagraphs(Document.paragraphs(from: result.answer), in: document.id)
            wwLog(String(format: "Preset “%@” finished in %.1fs (%d chars)", preset.name,
                         Date().timeIntervalSince(start), result.answer.count), .transform)
        } catch {
            setupError = error.localizedDescription
            wwLog("Transform failed: \(error.localizedDescription)", .error)
        }
    }

    /// Run a preset against a single paragraph, replacing that paragraph's text in place.
    func transformParagraph(_ preset: PromptPreset,
                            paragraphID: UUID,
                            in documentID: UUID,
                            onToken: (@Sendable (TransformToken) -> Void)? = nil) async {
        guard let source = documents.document(with: documentID)?
            .paragraphs.first(where: { $0.id == paragraphID })?.text,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        wwLog("Transforming a paragraph with “\(preset.name)”…", .transform)
        do {
            let result = try await transform.transform(transcript: source, with: preset, onToken: onToken)
            documents.replaceParagraph(paragraphID, in: documentID, withTextSplitInto: result.answer)
            wwLog(String(format: "Paragraph transform “%@” finished (%d chars)", preset.name,
                         result.answer.count), .transform)
        } catch {
            setupError = error.localizedDescription
            wwLog("Transform failed: \(error.localizedDescription)", .error)
        }
    }
}
