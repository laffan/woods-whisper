import Foundation

/// One unit of work sent from a recording device (Watch) to a host (iPhone/iPad): the
/// recording metadata plus a reference to its audio bytes.
public struct RecordingTransfer: Codable, Sendable {
    public var recording: Recording
    /// Size of the audio payload in bytes, for progress reporting.
    public var byteCount: Int
    /// Pairing secret (local-network transport only) so the host can authenticate the sender.
    public var pairingSecret: String?

    public init(recording: Recording, byteCount: Int, pairingSecret: String? = nil) {
        self.recording = recording
        self.byteCount = byteCount
        self.pairingSecret = pairingSecret
    }
}

/// Sends recordings from this device to a paired host. Implemented by both the
/// WatchConnectivity transport and the local-network transport.
public protocol RecordingSender: AnyObject {
    var isReachable: Bool { get }
    /// Send a recording (metadata + audio file at `audioURL`) to the paired host.
    /// `progress`, if given, is called with a 0...1 fraction as bytes go out (transports that
    /// can't report granularly — WCSession, a single WiFi write — simply don't call it).
    func send(_ transfer: RecordingTransfer, audioURL: URL,
              progress: (@Sendable (Double) -> Void)?) async throws
}

public extension RecordingSender {
    /// Convenience for callers that don't need progress.
    func send(_ transfer: RecordingTransfer, audioURL: URL) async throws {
        try await send(transfer, audioURL: audioURL, progress: nil)
    }
}

/// Receives recordings on a host device. The host persists them via `RecordingStore`.
public protocol RecordingReceiver: AnyObject {
    /// Called on the main actor when a complete recording (metadata + bytes) arrives.
    var onReceive: (@MainActor (RecordingTransfer, Data) -> Void)? { get set }
    func start() throws
    func stop()
}

public enum ConnectivityError: Error, LocalizedError {
    case notReachable
    case notAuthorized
    case noEndpointConfigured
    case authenticationFailed
    case transportFailure(Error)

    public var errorDescription: String? {
        switch self {
        case .notReachable: return "The paired device isn't reachable right now."
        case .notAuthorized: return "Connectivity isn't authorized on this device."
        case .noEndpointConfigured: return "No paired iPad address configured. Pair first in setup."
        case .authenticationFailed: return "The iPad rejected the pairing secret."
        case .transportFailure(let error): return error.localizedDescription
        }
    }
}
