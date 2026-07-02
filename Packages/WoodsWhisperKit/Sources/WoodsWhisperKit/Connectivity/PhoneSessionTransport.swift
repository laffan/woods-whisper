import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity

/// WatchConnectivity transport. Used on BOTH sides:
///  • Watch  → acts as `RecordingSender` (sends to the paired iPhone).
///  • iPhone → acts as `RecordingReceiver` (receives from the Watch).
///
/// This is the supported, reliable path for the Watch↔iPhone pairing. (iPad cannot be the
/// peer here — WCSession only talks to the Watch's paired iPhone — hence the separate
/// local-network transport for the Watch↔iPad case.)
public final class PhoneSessionTransport: NSObject, RecordingSender, RecordingReceiver {

    public var onReceive: (@MainActor (RecordingTransfer, Data) -> Void)?

    /// Called on the main actor when an updated document list arrives (iPhone → Watch). Used by the
    /// Watch to refresh its record-target picker.
    public var onReceiveDocuments: (@MainActor ([DocumentDescriptor]) -> Void)?

    /// Supplies the current document list on demand (iPhone side), so a Watch "Refresh Documents"
    /// request can be answered live.
    public var onDocumentsRequested: (@MainActor () -> [DocumentDescriptor])?

    private let session: WCSession?

    /// Key under which the synced document list rides in the WatchConnectivity application context.
    private static let documentsContextKey = "documents"
    /// Message key the Watch sends to pull a fresh document list from the iPhone.
    private static let requestDocumentsKey = "requestDocuments"

    public override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    public var isReachable: Bool {
        session?.isReachable ?? false
    }

    public func start() throws {
        guard let session else { throw ConnectivityError.notAuthorized }
        session.delegate = self
        session.activate()
    }

    public func stop() { /* WCSession has no deactivate; nothing to do. */ }

    // MARK: Document sync (iPhone → Watch)

    /// Push the current document list to the Watch. Uses `updateApplicationContext`, which keeps only
    /// the latest state and delivers it in the background — exactly right for a small, replace-wholesale
    /// list that only the most recent version matters for. Safe to call often; identical contexts throw
    /// and are ignored.
    public func sendDocuments(_ descriptors: [DocumentDescriptor]) {
        guard let session else { return }
        guard let data = try? JSONEncoder.iso.encode(descriptors) else { return }
        do {
            try session.updateApplicationContext([Self.documentsContextKey: data])
            wwLog("Synced \(descriptors.count) document(s) to Watch", .transfer)
        } catch {
            // WCSession throws if the payload is unchanged, or if the session isn't activated yet —
            // neither is worth surfacing.
        }
    }

    /// The most recently received document list, read from WCSession's retained application context so
    /// the Watch has targets immediately on launch (before a fresh push arrives).
    public var latestReceivedDocuments: [DocumentDescriptor] {
        guard let data = session?.receivedApplicationContext[Self.documentsContextKey] as? Data,
              let decoded = try? JSONDecoder.iso.decode([DocumentDescriptor].self, from: data)
        else { return [] }
        return decoded
    }

    /// Pull a fresh document list from the iPhone now (Watch side, backs "Refresh Documents"). Sends
    /// an interactive message when the iPhone is reachable and replies with the fresh list; when it
    /// isn't reachable, falls back to whatever context is already retained on this device. `reply` is
    /// always called once, on the main actor.
    public func requestDocuments(reply: @escaping @MainActor ([DocumentDescriptor]) -> Void) {
        guard let session, session.isReachable else {
            let cached = latestReceivedDocuments
            Task { @MainActor in reply(cached) }
            return
        }
        session.sendMessage([Self.requestDocumentsKey: true], replyHandler: { response in
            let descriptors: [DocumentDescriptor]
            if let data = response[Self.documentsContextKey] as? Data,
               let decoded = try? JSONDecoder.iso.decode([DocumentDescriptor].self, from: data) {
                descriptors = decoded
            } else {
                descriptors = []
            }
            Task { @MainActor in reply(descriptors) }
        }, errorHandler: { [weak self] _ in
            let cached = self?.latestReceivedDocuments ?? []
            Task { @MainActor in reply(cached) }
        })
    }

    // MARK: RecordingSender (Watch side)

    public func send(_ transfer: RecordingTransfer, audioURL: URL,
                     progress: (@Sendable (Double) -> Void)?) async throws {
        // WCSession queues the file and delivers it in the background, so there's no live
        // byte-progress to report; `progress` is intentionally unused here.
        guard let session else { throw ConnectivityError.notAuthorized }
        guard let metadataData = try? JSONEncoder.iso.encode(transfer),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        else { throw ConnectivityError.transportFailure(EncodingFailure()) }

        // transferFile reliably delivers even if the iPhone app is backgrounded; the system
        // queues and retries. The metadata dictionary rides along with the file.
        session.transferFile(audioURL, metadata: ["transfer": metadata])
        wwLog("Sending “\(transfer.recording.name)” to iPhone via WatchConnectivity "
              + "(reachable: \(session.isReachable))", .transfer)
    }

    private struct EncodingFailure: Error {}
}

extension PhoneSessionTransport: WCSessionDelegate {
    public func session(_ session: WCSession,
                        activationDidCompleteWith state: WCSessionActivationState,
                        error: Error?) {
        if let error {
            wwLog("WatchConnectivity activation error: \(error.localizedDescription)", .error)
        } else {
            wwLog("WatchConnectivity activated (state: \(state.rawValue))", .transfer)
        }
        // Deliver any document list retained from a previous push now that the session is active —
        // `didReceiveApplicationContext` only fires for *new* contexts, so the Watch would otherwise
        // never adopt a list that arrived before it launched. (No-op on iPhone, which doesn't set
        // `onReceiveDocuments`.)
        if let data = session.receivedApplicationContext[Self.documentsContextKey] as? Data,
           let descriptors = try? JSONDecoder.iso.decode([DocumentDescriptor].self, from: data) {
            let handler = onReceiveDocuments
            Task { @MainActor in handler?(descriptors) }
        }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    // MARK: Document request (iPhone side)

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                        replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[Self.requestDocumentsKey] != nil else { replyHandler([:]); return }
        let provider = onDocumentsRequested
        Task { @MainActor in
            let descriptors = provider?() ?? []
            if let data = try? JSONEncoder.iso.encode(descriptors) {
                replyHandler([Self.documentsContextKey: data])
                // Also refresh the retained context so future launches have it without a request.
                self.sendDocuments(descriptors)
            } else {
                replyHandler([:])
            }
            wwLog("Answered Watch document refresh (\(descriptors.count) documents)", .transfer)
        }
    }

    // MARK: Document sync receiver (Watch side)

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[Self.documentsContextKey] as? Data,
              let descriptors = try? JSONDecoder.iso.decode([DocumentDescriptor].self, from: data)
        else { return }
        wwLog("Received \(descriptors.count) document(s) from iPhone", .transfer)
        let handler = onReceiveDocuments
        Task { @MainActor in handler?(descriptors) }
    }

    // MARK: RecordingReceiver (iPhone side)

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        wwLog("WatchConnectivity file received from Watch", .transfer)
        guard
            let wrapper = file.metadata?["transfer"] as? [String: Any],
            let metadataData = try? JSONSerialization.data(withJSONObject: wrapper),
            let transfer = try? JSONDecoder.iso.decode(RecordingTransfer.self, from: metadataData),
            let data = try? Data(contentsOf: file.fileURL)
        else {
            wwLog("Could not decode incoming WatchConnectivity file", .error)
            return
        }

        let handler = onReceive
        Task { @MainActor in handler?(transfer, data) }
    }
}
#endif
