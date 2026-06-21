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

    private let session: WCSession?

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

    // MARK: RecordingSender (Watch side)

    public func send(_ transfer: RecordingTransfer, audioURL: URL) async throws {
        guard let session else { throw ConnectivityError.notAuthorized }
        guard let metadataData = try? JSONEncoder.iso.encode(transfer),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        else { throw ConnectivityError.transportFailure(EncodingFailure()) }

        // transferFile reliably delivers even if the iPhone app is backgrounded; the system
        // queues and retries. The metadata dictionary rides along with the file.
        session.transferFile(audioURL, metadata: ["transfer": metadata])
    }

    private struct EncodingFailure: Error {}
}

extension PhoneSessionTransport: WCSessionDelegate {
    public func session(_ session: WCSession,
                        activationDidCompleteWith state: WCSessionActivationState,
                        error: Error?) {}

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    // MARK: RecordingReceiver (iPhone side)

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard
            let wrapper = file.metadata?["transfer"] as? [String: Any],
            let metadataData = try? JSONSerialization.data(withJSONObject: wrapper),
            let transfer = try? JSONDecoder.iso.decode(RecordingTransfer.self, from: metadataData),
            let data = try? Data(contentsOf: file.fileURL)
        else { return }

        let handler = onReceive
        Task { @MainActor in handler?(transfer, data) }
    }
}
#endif
