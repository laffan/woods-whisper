import Foundation
import SwiftUI
import Combine
import WoodsWhisperKit
#if canImport(WatchKit)
import WatchKit
#endif

/// Coordinator for the Watch app: records audio, stores it locally, and sends it to the paired
/// iOS device using the configured transport (paired iPhone via WatchConnectivity, or directly
/// to an iPad over the local network).
@MainActor
final class WatchModel: ObservableObject {
    let recordings = RecordingStore(directoryName: "WatchRecordings")

    @Published var statusMessage: String?
    @Published var pendingSends: Set<UUID> = []
    /// 0...1 upload progress per recording while sending (only populated by transports that
    /// report it — currently Bluetooth, where transfers are slow enough to matter).
    @Published var sendProgress: [UUID: Double] = [:]
    /// Outcome of the last send attempt per recording, for the ✓ / retry affordances.
    @Published var sendOutcome: [UUID: SendOutcome] = [:]
    /// Clips captured while Walking mode was on that haven't entered the send pipeline yet.
    /// Surfaced in a "Walking" section so they can be flushed after a walk. A clip leaves this set
    /// the moment a send is started for it (manually or via "Send Walking Clips").
    @Published var walkingClipIDs: Set<UUID> = []

    /// Documents synced from the iPhone, shown in the record-target picker (Inbox is offered on top
    /// of these). Seeded from the on-disk cache, refreshed as the iPhone pushes updates.
    @Published var documents: [DocumentDescriptor] = WatchSettings.shared.documents

    /// The chosen target document's id, or nil for the Inbox. Recordings captured while this is set
    /// are stamped so the host files them into that document.
    @Published var targetDocumentID: UUID? = WatchSettings.shared.targetDocumentID

    enum SendOutcome: Equatable { case sent, failed, cancelled }

    /// In-flight send tasks, kept so a send can be cancelled (e.g. the iPad is offline).
    private var sendTasks: [UUID: Task<Void, Never>] = [:]

    /// True while a pairing scan is running; `scanProgress` is `(hostsTried, hostsTotal)`.
    @Published var pairingInProgress = false
    @Published var scanProgress: (Int, Int)?

    #if canImport(WatchConnectivity)
    private let phone = PhoneSessionTransport()
    #endif
    private var cancellables = Set<AnyCancellable>()

    init() {
        // RecordingStore is its own ObservableObject; forward its changes so views observing
        // WatchModel re-render on edits like rename/delete (not just when a send updates state).
        recordings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        #if canImport(WatchConnectivity)
        // Refresh the target picker whenever the iPhone pushes an updated document list, and adopt
        // any list already retained in the session's application context at launch.
        phone.onReceiveDocuments = { [weak self] descriptors in
            self?.updateDocuments(descriptors)
        }
        try? phone.start()
        let cached = phone.latestReceivedDocuments
        if !cached.isEmpty { updateDocuments(cached) }
        #endif
    }

    /// Adopt a freshly synced document list: publish it, persist it, and drop the selected target if
    /// it no longer exists (so a deleted document can't strand recordings on the host).
    func updateDocuments(_ descriptors: [DocumentDescriptor]) {
        documents = descriptors
        WatchSettings.shared.documents = descriptors
        if let target = targetDocumentID, !descriptors.contains(where: { $0.id == target }) {
            selectTarget(nil)
        }
    }

    /// Choose the document new recordings should be filed into (nil = Inbox).
    func selectTarget(_ id: UUID?) {
        targetDocumentID = id
        WatchSettings.shared.targetDocumentID = id
    }

    /// True while a manual "Refresh Documents" pull is in flight (drives the button's spinner).
    @Published var isRefreshingDocuments = false

    /// Manually pull the document list from the iPhone (backs "Refresh Documents"). Adopts any
    /// already-retained list immediately, then asks the iPhone for a fresh one when it's reachable.
    func refreshDocuments() {
        #if canImport(WatchConnectivity)
        let cached = phone.latestReceivedDocuments
        if !cached.isEmpty { updateDocuments(cached) }
        isRefreshingDocuments = true
        phone.requestDocuments { [weak self] descriptors in
            guard let self else { return }
            self.isRefreshingDocuments = false
            if !descriptors.isEmpty { self.updateDocuments(descriptors) }
        }
        #endif
    }

    /// Display name of the current target ("Inbox" when none is chosen or it's gone missing).
    var targetName: String {
        guard let id = targetDocumentID else { return "Inbox" }
        return documents.first(where: { $0.id == id })?.title ?? "Inbox"
    }

    private func sender() -> RecordingSender? {
        switch WatchSettings.shared.transport {
        case .phoneSession:
            #if canImport(WatchConnectivity)
            return phone
            #else
            return nil
            #endif
        case .localNetwork:
            guard let link = WatchSettings.shared.deviceLink else { return nil }
            return LocalNetworkClient(link: link)
        case .bluetooth:
            guard let link = WatchSettings.shared.deviceLink else { return nil }
            return BluetoothRecordingClient(link: link)
        }
    }

    // MARK: Pairing

    /// Find the iPad showing `code` and save it as the paired device. Races the two direct
    /// transports — WiFi (subnet scan) and Bluetooth — so it works whether or not a network is
    /// available; the first to answer wins and its transport is stored. Returns true on success.
    func pair(code: String) async -> Bool {
        pairingInProgress = true
        scanProgress = nil
        statusMessage = "Searching for iPad…"
        defer { pairingInProgress = false; scanProgress = nil }

        let name = Self.deviceName
        let link = await withTaskGroup(of: DeviceLink?.self) { group -> DeviceLink? in
            group.addTask {
                try? await PairingClient.pair(code: code, deviceName: name) { tried, total in
                    Task { @MainActor in self.scanProgress = (tried, total) }
                }
            }
            group.addTask {
                try? await BluetoothPairing.pair(code: code, deviceName: name)
            }
            var winner: DeviceLink?
            for await result in group {
                if let result { winner = result; group.cancelAll(); break }
            }
            return winner
        }

        guard let link else {
            statusMessage = "Couldn't find the iPad. Make sure it's showing the pairing code."
            return false
        }
        WatchSettings.shared.deviceLink = link
        WatchSettings.shared.transport = link.transport
        let how = link.transport == .bluetooth ? "Bluetooth" : "WiFi"
        statusMessage = "Paired with \(link.displayName) over \(how)."
        return true
    }

    /// This Watch's name, sent to the iPad so it can confirm which Watch paired.
    static var deviceName: String {
        #if canImport(WatchKit)
        return WKInterfaceDevice.current().name
        #else
        return "Apple Watch"
        #endif
    }

    /// Persist a freshly recorded clip and attempt to send it to the paired device.
    func store(audioURL: URL, duration: TimeInterval) {
        let fileName = audioURL.lastPathComponent
        let name = Recording.defaultName(for: Date(), duration: duration,
                                         byteCount: Recording.fileSize(at: audioURL))
        let recording = Recording(name: name, duration: duration, audioFileName: fileName,
                                  origin: .watch, targetDocumentID: targetDocumentID)
        recordings.add(recording)
        // Walking mode: queue locally and send the batch later, instead of uploading each clip now.
        if WatchSettings.shared.walkingMode {
            walkingClipIDs.insert(recording.id)
            statusMessage = "Saved — walking mode, not sent yet."
        } else {
            startSend(recording)
        }
    }

    /// Clips queued during Walking mode, in list order.
    var walkingRecordings: [Recording] {
        recordings.recordings.filter { walkingClipIDs.contains($0.id) }
    }

    /// Send every clip queued during Walking mode (the "Send Walking Clips" button).
    func sendWalkingClips() {
        for recording in walkingRecordings { startSend(recording) }
    }

    /// Recordings that haven't been confirmed sent (queued in walking mode, or failed/cancelled).
    var unsentRecordings: [Recording] {
        recordings.recordings.filter { sendOutcome[$0.id] != .sent && !pendingSends.contains($0.id) }
    }

    /// Send every recording not yet confirmed sent — the "send the batch" action for walking mode.
    func sendAllUnsent() {
        for recording in unsentRecordings {
            sendOutcome[recording.id] = nil
            startSend(recording)
        }
    }

    /// Begin sending a recording (recorded just now, or a manual re-send), tracking the task so it
    /// can be cancelled. No-op if a send for this clip is already in flight.
    func startSend(_ recording: Recording) {
        guard sendTasks[recording.id] == nil, !pendingSends.contains(recording.id) else { return }
        walkingClipIDs.remove(recording.id)   // entering the send pipeline; no longer a queued walking clip
        sendTasks[recording.id] = Task { await self.send(recording) }
    }

    /// Cancel an in-flight send (e.g. the iPad isn't online). The clip is marked cancelled so it
    /// lands in the "Needs Resend" section, where the user can switch targets and resend.
    func cancelSend(_ recording: Recording) {
        let id = recording.id
        sendTasks[id]?.cancel()
        pendingSends.remove(id)
        sendProgress[id] = nil
        sendOutcome[id] = .cancelled
        statusMessage = "Send cancelled."
    }

    /// Cancel every in-flight send.
    func cancelAllSends() {
        for id in pendingSends {
            sendTasks[id]?.cancel()
            sendProgress[id] = nil
            sendOutcome[id] = .cancelled
        }
        pendingSends.removeAll()
        statusMessage = "Send cancelled."
    }

    /// Delete every recording on the Watch (the "Delete All" action): cancel any in-flight sends,
    /// wipe the store, and clear per-recording send state.
    func deleteAllRecordings() {
        cancelAllSends()
        recordings.deleteAll()
        sendOutcome.removeAll()
        sendProgress.removeAll()
        walkingClipIDs.removeAll()
        statusMessage = nil
    }

    /// Resend everything that previously failed or was cancelled (after, perhaps, switching targets).
    func resendFailed() {
        for recording in recordings.recordings
        where sendOutcome[recording.id] == .failed || sendOutcome[recording.id] == .cancelled {
            sendOutcome[recording.id] = nil
            startSend(recording)
        }
    }

    /// Send (or re-send) a recording to the paired device.
    func send(_ recording: Recording) async {
        guard let sender = sender() else {
            statusMessage = "No paired device configured."
            sendTasks[recording.id] = nil
            return
        }
        let id = recording.id
        pendingSends.insert(id)
        sendOutcome[id] = nil
        defer {
            pendingSends.remove(id)
            sendProgress[id] = nil
            sendTasks[id] = nil
        }

        let url = recordings.audioURL(for: recording)
        let byteCount = (try? Data(contentsOf: url).count) ?? 0
        let transfer = RecordingTransfer(recording: recording, byteCount: byteCount)
        do {
            try await sender.send(transfer, audioURL: url) { fraction in
                Task { @MainActor in self.sendProgress[id] = fraction }
            }
            if Task.isCancelled {
                sendOutcome[id] = .cancelled
            } else {
                sendOutcome[id] = .sent
                statusMessage = "Sent to \(WatchSettings.shared.deviceLink?.displayName ?? "iPhone")."
            }
        } catch is CancellationError {
            sendOutcome[id] = .cancelled    // cancelSend already set UI state; keep it consistent
        } catch {
            // A cancelled NWConnection surfaces as a transport error, not CancellationError — treat
            // an explicitly-cancelled task as cancelled rather than failed.
            sendOutcome[id] = Task.isCancelled ? .cancelled : .failed
            if !Task.isCancelled {
                statusMessage = "Send failed: \(error.localizedDescription)"
            }
        }
    }
}
